#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
team_id="${PEEK_TEAM_ID:-4DXU5FSLLY}"
notary_profile="${PEEK_NOTARY_PROFILE:-tracehalo-notary}"
notary_timeout="${PEEK_NOTARY_TIMEOUT:-1h}"
requested_identity="${PEEK_DEVELOPER_IDENTITY:-}"
release_stamp="$(date -u +%Y%m%dT%H%M%SZ)"

fail() {
  print -u2 -- "$1"
  exit "${2:-1}"
}

if [[ -n "$(git -C "$project_root" status --porcelain --untracked-files=normal)" ]]; then
  fail "Refusing to package a dirty working tree. Commit the reviewed release candidate first." 65
fi

source_revision="$(git -C "$project_root" rev-parse --verify HEAD)"
version_values="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);/\1/p' "$project_root/PEEK.xcodeproj/project.pbxproj" | sort -u)"
build_values="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);/\1/p' "$project_root/PEEK.xcodeproj/project.pbxproj" | sort -u)"
[[ "$(print -r -- "$version_values" | wc -l | tr -d ' ')" == "1" ]] \
  || fail "Expected one MARKETING_VERSION, found: $version_values"
[[ "$(print -r -- "$build_values" | wc -l | tr -d ' ')" == "1" ]] \
  || fail "Expected one CURRENT_PROJECT_VERSION, found: $build_values"
version="$version_values"
build_number="$build_values"

output_dir="${1:-/private/tmp/PEEK-v${version}-${release_stamp}}"
[[ ! -e "$output_dir" ]] || fail "Output already exists: $output_dir" 73

identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [[ -n "$requested_identity" ]]; then
  identity_line="$(print -r -- "$identities" | grep -F -- "$requested_identity" | grep -F 'Developer ID Application:' | grep -F "($team_id)" | head -n 1 || true)"
else
  identity_line="$(print -r -- "$identities" | awk -v team="($team_id)" '/Developer ID Application:/ && index($0, team) { print; exit }')"
fi
[[ -n "$identity_line" ]] \
  || fail "No valid Developer ID Application identity with a private key is available for Team $team_id." 69
identity_hash="$(print -r -- "$identity_line" | awk '{ print $2 }')"
identity_name="$(print -r -- "$identity_line" | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ "(.*)"$/\1/')"

work_root="$(mktemp -d /private/tmp/PEEK-github-release.XXXXXX)"
derived_root="$work_root/DerivedData"
unsigned_app="$derived_root/Build/Products/Release/PEEK.app"
signed_app="$work_root/PEEK.app"
app_notary_zip="$work_root/PEEK-app-notary.zip"
dmg_stage="$work_root/dmg-stage"
dmg_path="$work_root/PEEK-${version}-macOS-universal.dmg"
zip_path="$work_root/PEEK-${version}-macOS-universal.zip"
app_notary_result="$work_root/app-notary.json"
dmg_notary_result="$work_root/dmg-notary.json"

cleanup() {
  local exit_status=$?
  if [[ "$exit_status" != "0" ]]; then
    print -u2 -- "Release failed. Diagnostics retained at: $work_root"
    trap - EXIT
    exit "$exit_status"
  fi
  rm -rf "$work_root"
}
trap cleanup EXIT

xcrun notarytool history \
  --keychain-profile "$notary_profile" \
  --output-format json >/dev/null \
  || fail "Notary profile '$notary_profile' is missing or invalid." 69

"$project_root/scripts/verify-release.sh"

xcodebuild \
  -project "$project_root/PEEK.xcodeproj" \
  -scheme PEEK \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_root" \
  CODE_SIGNING_ALLOWED=NO \
  clean build

[[ -d "$unsigned_app" ]] || fail "Release app was not produced: $unsigned_app"
ditto "$unsigned_app" "$signed_app"

codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp \
  --entitlements "$project_root/PEEK/PEEK.entitlements" \
  --sign "$identity_hash" \
  "$signed_app"

codesign --verify --deep --strict --verbose=4 "$signed_app"
signature_details="$(codesign --display --verbose=4 "$signed_app" 2>&1)"
[[ "$signature_details" == *"Authority=Developer ID Application: Hao Xie ($team_id)"* ]] \
  || fail "Developer ID authority verification failed."
[[ "$signature_details" == *"TeamIdentifier=$team_id"* ]] \
  || fail "Unexpected TeamIdentifier."
[[ "$signature_details" == *"flags="*"runtime"* ]] \
  || fail "Hardened Runtime is missing."
[[ "$signature_details" == *"Timestamp="* ]] \
  || fail "Trusted timestamp is missing."
lipo "$signed_app/Contents/MacOS/PEEK" -verify_arch arm64 x86_64

ditto -c -k --sequesterRsrc --keepParent "$signed_app" "$app_notary_zip"
xcrun notarytool submit "$app_notary_zip" \
  --keychain-profile "$notary_profile" \
  --wait \
  --timeout "$notary_timeout" \
  --output-format json > "$app_notary_result"
app_notary_status="$(plutil -extract status raw -o - "$app_notary_result")"
app_submission_id="$(plutil -extract id raw -o - "$app_notary_result")"
[[ "$app_notary_status" == "Accepted" ]] \
  || fail "Apple rejected app notarization submission $app_submission_id: $app_notary_status"

xcrun stapler staple "$signed_app"
xcrun stapler validate "$signed_app"
codesign --verify --deep --strict --verbose=4 "$signed_app"
spctl --assess --type execute --verbose=4 "$signed_app"

ditto -c -k --sequesterRsrc --keepParent "$signed_app" "$zip_path"
mkdir -p "$dmg_stage"
ditto "$signed_app" "$dmg_stage/PEEK.app"
ln -s /Applications "$dmg_stage/Applications"
hdiutil create \
  -volname "PEEK $version" \
  -srcfolder "$dmg_stage" \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$dmg_path" >/dev/null
codesign \
  --force \
  --timestamp \
  --identifier com.shawnshoper.peek.dmg \
  --sign "$identity_hash" \
  "$dmg_path"
codesign --verify --strict --verbose=4 "$dmg_path"
hdiutil verify "$dmg_path" >/dev/null

xcrun notarytool submit "$dmg_path" \
  --keychain-profile "$notary_profile" \
  --wait \
  --timeout "$notary_timeout" \
  --output-format json > "$dmg_notary_result"
dmg_notary_status="$(plutil -extract status raw -o - "$dmg_notary_result")"
dmg_submission_id="$(plutil -extract id raw -o - "$dmg_notary_result")"
[[ "$dmg_notary_status" == "Accepted" ]] \
  || fail "Apple rejected DMG notarization submission $dmg_submission_id: $dmg_notary_status"

xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
hdiutil verify "$dmg_path" >/dev/null
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"

mkdir -p "$output_dir"
ditto "$dmg_path" "$output_dir/${dmg_path:t}"
ditto "$zip_path" "$output_dir/${zip_path:t}"
cp "$project_root/docs/releases/v${version}.md" "$output_dir/RELEASE_NOTES.md"

architectures="$(lipo -archs "$signed_app/Contents/MacOS/PEEK")"
{
  print -- "PEEK $version ($build_number)"
  print -- "Git revision: $source_revision"
  print -- "Architectures: $architectures"
  print -- "Signing identity: $identity_name"
  print -- "Team ID: $team_id"
  print -- "Hardened Runtime: enabled"
  print -- "App notarization: $app_notary_status ($app_submission_id)"
  print -- "DMG notarization: $dmg_notary_status ($dmg_submission_id)"
  print -- "Created UTC: $release_stamp"
} > "$output_dir/release-manifest.txt"

(
  cd "$output_dir"
  shasum -a 256 \
    "${dmg_path:t}" \
    "${zip_path:t}" \
    RELEASE_NOTES.md \
    release-manifest.txt > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)

print -- "GitHub release artifacts created and verified: $output_dir"
print -- "Source revision: $source_revision"
print -- "App notarization: $app_submission_id"
print -- "DMG notarization: $dmg_submission_id"
