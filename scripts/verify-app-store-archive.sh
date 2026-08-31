#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/PEEK.xcarchive" >&2
  exit 64
fi

archive_path="$1"
app_path="$archive_path/Products/Applications/PEEK.app"
info_path="$archive_path/Info.plist"
privacy_path="$app_path/Contents/Resources/PrivacyInfo.xcprivacy"
test -d "$archive_path"
test -d "$app_path"
test -s "$info_path"
test -s "$privacy_path"
plutil -lint "$info_path" >/dev/null
plutil -lint "$privacy_path" >/dev/null
"${0:A:h}/verify-privacy-manifest.sh" "$privacy_path"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")"

test "$bundle_id" = "com.shawnshoper.peek"
test "$short_version" = "0.3.0"
test "$build_version" = "3"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app_path/Contents/Info.plist")" = "13.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$app_path/Contents/Info.plist")" = "public.app-category.productivity"
test "$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$app_path/Contents/Info.plist")" = "false"
test "$(/usr/libexec/PlistBuddy -c 'Print :NSHumanReadableCopyright' "$app_path/Contents/Info.plist")" = "Copyright © 2026 ShawnShoper. All rights reserved."
lipo "$app_path/Contents/MacOS/PEEK" -verify_arch x86_64 arm64
if ! signature_result="$(codesign --verify --deep --strict --verbose=2 "$app_path" 2>&1)"; then
  print -r -- "$signature_result" >&2
  if [[ "$signature_result" == *"CSSMERR_TP_NOT_TRUSTED"* ]]; then
    echo "Archive signature is structurally present, but the signing certificate is not trusted by this Mac. Renew or repair the certificate chain in Xcode before App Store export." >&2
  fi
  exit 1
fi

signature_details="$(codesign --display --verbose=4 "$app_path" 2>&1)"
if [[ "$signature_details" != *"TeamIdentifier=4DXU5FSLLY"* ]]; then
  echo "Archive is not signed by the expected development team 4DXU5FSLLY." >&2
  exit 1
fi

# Current codesign may embed only the DER entitlement representation. Request
# its stable abstract display instead of forcing XML, which incorrectly reports
# a valid DER-only signature as an invalid entitlement blob on newer macOS.
entitlements_result="$(codesign --display --entitlements - "$app_path" 2>/dev/null)"
if print -r -- "$entitlements_result" | awk '
  /\[Key\] com\.apple\.security\.app-sandbox/ { found_key = 1; next }
  found_key && /\[Bool\] true/ { found_value = 1; exit }
  found_key && /\[Key\]/ { exit }
  END { exit(found_value ? 0 : 1) }
'; then
  :
else
  echo "Archive app is not sandboxed." >&2
  exit 1
fi

if print -r -- "$entitlements_result" | awk '
  /\[Key\] com\.apple\.security\.get-task-allow/ { found_key = 1; next }
  found_key && /\[Bool\] true/ { found_value = 1; exit }
  found_key && /\[Key\]/ { exit }
  END { exit(found_value ? 0 : 1) }
'; then
  echo "Archive contains the debug-only get-task-allow entitlement." >&2
  exit 1
fi

binary_uuid="$(dwarfdump --uuid "$app_path/Contents/MacOS/PEEK" | awk '{print $2}' | sort)"
dsym_path="$archive_path/dSYMs/PEEK.app.dSYM/Contents/Resources/DWARF/PEEK"
test -s "$dsym_path"
dsym_uuid="$(dwarfdump --uuid "$dsym_path" | awk '{print $2}' | sort)"
test "$binary_uuid" = "$dsym_uuid"

echo "Archive verified: $bundle_id $short_version ($build_version), Universal 2, signed by the expected team, sandboxed, matching dSYM, and privacy declarations verified."
