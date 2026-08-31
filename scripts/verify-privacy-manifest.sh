#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/PrivacyInfo.xcprivacy" >&2
  exit 64
fi

privacy_path="$1"
test -s "$privacy_path"
plutil -lint "$privacy_path" >/dev/null

extract_raw() {
  plutil -extract "$1" raw -o - "$privacy_path"
}

test "$(extract_raw NSPrivacyTracking)" = "false"
test "$(extract_raw NSPrivacyAccessedAPITypes)" = "3"
test "$(extract_raw NSPrivacyCollectedDataTypes)" = "1"
test "$(extract_raw NSPrivacyCollectedDataTypes.0.NSPrivacyCollectedDataType)" \
  = "NSPrivacyCollectedDataTypeOtherUserContent"
test "$(extract_raw NSPrivacyCollectedDataTypes.0.NSPrivacyCollectedDataTypeLinked)" = "false"
test "$(extract_raw NSPrivacyCollectedDataTypes.0.NSPrivacyCollectedDataTypeTracking)" = "false"
test "$(extract_raw NSPrivacyCollectedDataTypes.0.NSPrivacyCollectedDataTypePurposes)" = "1"
test "$(extract_raw NSPrivacyCollectedDataTypes.0.NSPrivacyCollectedDataTypePurposes.0)" \
  = "NSPrivacyCollectedDataTypePurposeAppFunctionality"

typeset -A expected_reasons
expected_reasons[NSPrivacyAccessedAPICategoryFileTimestamp]='3B52.1 C617.1 DDA9.1'
expected_reasons[NSPrivacyAccessedAPICategorySystemBootTime]='35F9.1'
expected_reasons[NSPrivacyAccessedAPICategoryUserDefaults]='CA92.1'

typeset -A found_categories
for index in {0..2}; do
  category="$(extract_raw NSPrivacyAccessedAPITypes.${index}.NSPrivacyAccessedAPIType)"
  expected="${expected_reasons[$category]-}"
  if [[ -z "$expected" ]]; then
    echo "Unexpected required-reason API category: $category" >&2
    exit 1
  fi
  if [[ -n "${found_categories[$category]-}" ]]; then
    echo "Duplicate required-reason API category: $category" >&2
    exit 1
  fi
  found_categories[$category]=1

  reason_count="$(extract_raw NSPrivacyAccessedAPITypes.${index}.NSPrivacyAccessedAPITypeReasons)"
  actual_reasons=()
  for ((reason_index = 0; reason_index < reason_count; reason_index++)); do
    actual_reasons+=("$(extract_raw NSPrivacyAccessedAPITypes.${index}.NSPrivacyAccessedAPITypeReasons.${reason_index})")
  done
  actual="$(print -rl -- "${actual_reasons[@]}" | LC_ALL=C sort | paste -sd' ' -)"
  if [[ "$actual" != "$expected" ]]; then
    echo "Incorrect reasons for $category: expected '$expected', found '$actual'" >&2
    exit 1
  fi
done

for category in ${(k)expected_reasons}; do
  if [[ -z "${found_categories[$category]-}" ]]; then
    echo "Missing required-reason API category: $category" >&2
    exit 1
  fi
done

if plutil -extract NSPrivacyTrackingDomains raw -o - "$privacy_path" >/dev/null 2>&1; then
  echo "NSPrivacyTrackingDomains must be omitted when tracking is disabled." >&2
  exit 1
fi

echo "Privacy manifest verified: required-reason APIs, cloud user content, and tracking declarations are consistent."
