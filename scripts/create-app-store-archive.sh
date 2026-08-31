#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
archive_path="${1:-${TMPDIR:-/tmp}/PEEK-AppStore.xcarchive}"

if [[ -n "$(git -C "$project_root" status --porcelain --untracked-files=normal)" ]]; then
  echo "Refusing to archive a dirty working tree." >&2
  echo "Commit the reviewed release candidate so the App Store binary maps to one Git revision." >&2
  exit 65
fi

source_revision="$(git -C "$project_root" rev-parse --verify HEAD)"
if ! security find-identity -v -p codesigning | grep -Eq \
  'Apple Distribution: .+ \(4DXU5FSLLY\)'; then
  echo "No valid Apple Distribution identity for Team 4DXU5FSLLY is available in the active keychains." >&2
  echo "Create or repair the distribution certificate in Xcode before creating an App Store archive." >&2
  exit 69
fi

if [[ -e "$archive_path" ]]; then
  echo "Archive already exists: $archive_path" >&2
  echo "Choose a new archive path so an earlier release is never overwritten." >&2
  exit 73
fi

xcodebuild archive \
  -project "$project_root/PEEK.xcodeproj" \
  -scheme PEEK \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic

"$project_root/scripts/verify-app-store-archive.sh" "$archive_path"

print -r -- "$source_revision" > "${archive_path}.source-revision.txt"

echo "Archive created at: $archive_path"
echo "Source revision: $source_revision"
echo "Upload it from Xcode Organizer using TestFlight & App Store automatic distribution signing."
