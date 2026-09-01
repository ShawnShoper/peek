#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
derived_root="${TMPDIR:-/tmp}/PEEKVerifyDerivedData"
project_path="$project_root/PEEK.xcodeproj"
test_bundle="$derived_root/Build/Products/Debug/PEEK.app/Contents/PlugIns/PEEKTests.xctest"
debug_dylib="$derived_root/Build/Products/Debug/PEEK.app/Contents/MacOS/PEEK.debug.dylib"
frameworks_dir="$test_bundle/Contents/Frameworks"
release_app="$derived_root/Build/Products/Release/PEEK.app"

"$project_root/scripts/verify-localizations.sh"

xcodebuild \
  -project "$project_path" \
  -scheme PEEK \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_root" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  build-for-testing

mkdir -p "$frameworks_dir"
cp "$debug_dylib" "$frameworks_dir/PEEK.debug.dylib"
LLVM_PROFILE_FILE="$derived_root/coverage-%p.profraw" xcrun xctest "$test_bundle"

xcodebuild \
  -project "$project_path" \
  -scheme PEEK \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_root" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  analyze

xcodebuild \
  -project "$project_path" \
  -scheme PEEK \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_root" \
  CODE_SIGNING_ALLOWED=NO \
  build

lipo "$release_app/Contents/MacOS/PEEK" -verify_arch x86_64 arm64
test -f "$release_app/Contents/Resources/Assets.car"
test -s "$release_app/Contents/Resources/PrivacyPolicy.zh-Hans.md"
test -s "$release_app/Contents/Resources/PrivacyPolicy.en.md"
test -s "$release_app/Contents/Resources/PrivacyInfo.xcprivacy"
plutil -lint "$project_root/PEEK/Resources/PrivacyInfo.xcprivacy" >/dev/null
plutil -lint "$release_app/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null
"$project_root/scripts/verify-privacy-manifest.sh" \
  "$project_root/PEEK/Resources/PrivacyInfo.xcprivacy"
"$project_root/scripts/verify-privacy-manifest.sh" \
  "$release_app/Contents/Resources/PrivacyInfo.xcprivacy"
if grep -Fq \
  'https://github.com/ShawnShoper/peek/blob/master/PRIVACY.md' \
  "$project_root/PEEK/Views/SettingsView.swift"; then
  echo "Settings must open the bundled privacy policy instead of GitHub." >&2
  exit 1
fi
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$release_app/Contents/Info.plist")" = "0.3.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$release_app/Contents/Info.plist")" = "4"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$release_app/Contents/Info.plist")" = "public.app-category.productivity"
test "$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$release_app/Contents/Info.plist")" = "false"

echo "PEEK verification passed: localization, tests, Release Analyze, Universal 2, AppIcon assets, bundled privacy policies, privacy manifest, version 0.3.0 (4)."
