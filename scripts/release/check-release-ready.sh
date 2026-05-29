#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

failures=()

require_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    failures+=("missing file: $path")
  fi
}

require_grep() {
  local pattern="$1"
  local path="$2"
  local description="$3"
  if [ ! -f "$path" ] || ! grep -Eq "$pattern" "$path"; then
    failures+=("$description")
  fi
}

require_no_grep() {
  local pattern="$1"
  local path="$2"
  local description="$3"
  if [ -f "$path" ] && grep -Eiq "$pattern" "$path"; then
    failures+=("$description")
  fi
}

require_file ".github/workflows/ci.yml"
require_file ".githooks/pre-commit"
require_file ".githooks/commit-msg"
require_file "scripts/install-githooks.sh"
require_file "scripts/release/build-unsigned-archive.sh"
require_file "docs/release/signed-build-runbook.md"
require_file "docs/release/release-checklist.md"
require_file "Dspeech/PrivacyInfo.xcprivacy"
require_file "docs/product/app-store/export-compliance.md"
require_file "docs/product/app-store/listing-en.md"
require_file "docs/product/app-store/privacy-nutrition-labels-mapping.md"
require_file "docs/product/app-store/testflight-setup.md"

require_app_store_locale() {
  local locale="$1"
  require_file "docs/product/app-store/listing-${locale}.md"
}

for locale in de es fr ja ko pt ru zh-Hans; do
  require_app_store_locale "$locale"
done

require_grep "pull_request:" ".github/workflows/ci.yml" "CI must run on pull_request"
require_grep "branches:" ".github/workflows/ci.yml" "CI push branches must be configured"
require_grep "macos-26" ".github/workflows/ci.yml" "CI must use macos-26 for iOS 26 simulator"
require_grep "select-ios-simulator\\.sh" ".github/workflows/ci.yml" "CI must select an available iOS 26 simulator from the selected Xcode"
require_grep "swift format lint --strict --recursive" ".github/workflows/ci.yml" "CI must run strict swift format lint"
require_grep "gitleaks git --redact --verbose" ".github/workflows/ci.yml" "CI must run gitleaks with redaction"
require_grep "fetch-depth: 0" ".github/workflows/ci.yml" "Gitleaks action checkout must use full history"
require_grep "NSPrivacyAccessedAPICategoryUserDefaults" "Dspeech/PrivacyInfo.xcprivacy" "Privacy manifest must declare UserDefaults required-reason API"
require_grep "CA92\\.1" "Dspeech/PrivacyInfo.xcprivacy" "Privacy manifest must include UserDefaults reason CA92.1"
require_grep "NSPrivacyTracking" "Dspeech/PrivacyInfo.xcprivacy" "Privacy manifest must declare tracking flag"
require_grep "PrivacyInfo\\.xcprivacy in Resources" "Dspeech.xcodeproj/project.pbxproj" "Privacy manifest must be included as app target resource"
require_grep "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO" "Dspeech.xcodeproj/project.pbxproj" "Export compliance Info.plist key must be set to NO"
require_grep "CODE_SIGNING_ALLOWED=NO" "scripts/release/build-unsigned-archive.sh" "Unsigned archive script must disable code signing"
require_grep "tmp/release/Dspeech\\.xcarchive" "scripts/release/build-unsigned-archive.sh" "Unsigned archive output path must be tmp/release/Dspeech.xcarchive"
if [ ! -d "tmp/release/Dspeech.xcarchive" ]; then
  failures+=("missing unsigned archive: tmp/release/Dspeech.xcarchive")
elif [ ! -d "tmp/release/Dspeech.xcarchive/Products" ] || [ ! -f "tmp/release/Dspeech.xcarchive/Info.plist" ]; then
  failures+=("unsigned archive is incomplete: tmp/release/Dspeech.xcarchive")
fi
for op_ref in \
  "op://MyInfra-Active/dspeech-apple-distribution-certificate/credential" \
  "op://MyInfra-Active/dspeech-apple-distribution-certificate-password/credential" \
  "op://MyInfra-Active/dspeech-app-store-provisioning-profile/credential" \
  "op://MyInfra-Active/dspeech-app-store-connect-api-key/credential" \
  "op://MyInfra-Active/dspeech-app-store-connect-api-key-id/credential" \
  "op://MyInfra-Active/dspeech-app-store-connect-issuer-id/credential"
do
  require_grep "$op_ref" "docs/release/signed-build-runbook.md" "Runbook must use op:// signing and ASC references"
  require_grep "$op_ref" "docs/product/app-store/testflight-setup.md" "TestFlight worksheet must use op:// signing and ASC references"
done
require_grep "op run --env-file" "docs/release/signed-build-runbook.md" "Runbook must use op run for upload credentials"
require_grep "Transporter|Xcode Organizer" "docs/release/signed-build-runbook.md" "Runbook must prefer Xcode or Transporter path"
require_grep "No CI submission automation" "docs/release/signed-build-runbook.md" "Runbook must block CI submission automation"
require_grep "privacy manifest present" "docs/release/release-checklist.md" "Checklist must include privacy manifest preflight"
require_grep "export compliance answer set" "docs/release/release-checklist.md" "Checklist must include export compliance"
require_grep "screenshots captured" "docs/release/release-checklist.md" "Checklist must include screenshots"
require_grep "listing-en" "docs/release/release-checklist.md" "Checklist must include listing-en"
require_grep "locales present" "docs/release/release-checklist.md" "Checklist must include locales"
require_grep "version bumped" "docs/release/release-checklist.md" "Checklist must include version bump"
require_grep "build monotonic" "docs/release/release-checklist.md" "Checklist must include monotonic build number"
require_grep "ASC build received TestFlight processing" "docs/release/release-checklist.md" "Checklist must include ASC TestFlight processing"
require_grep "internal testers added" "docs/release/release-checklist.md" "Checklist must include internal testers"
require_grep "canonical allowlist" "docs/release/release-checklist.md" "Checklist must require canonical availability allowlist"
require_grep "no outbound webhook/DM/email" "docs/release/release-checklist.md" "Checklist must explicitly block outbound integrations"
require_no_grep "slack|discord|webhook-url|mailgun|sendgrid|smtp" ".github/workflows/ci.yml" "CI must not include outbound notification integrations"
for listing in docs/product/app-store/listing-*.md; do
  require_no_grep "country availability|regional availability|market availability" "$listing" "App Store listing must not override canonical availability allowlist: $listing"
done

if ! find tmp/app-store-screenshots -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -print -quit 2>/dev/null | grep -q .; then
  failures+=("missing captured App Store screenshots under tmp/app-store-screenshots/")
fi

if [ "$(uname -s)" = "Darwin" ] && command -v plutil >/dev/null 2>&1; then
  plutil -lint Dspeech/PrivacyInfo.xcprivacy >/dev/null || failures+=("privacy manifest plutil lint failed")
fi

python3 - <<'PY' || failures+=("privacy manifest plist validation failed")
import plistlib
from pathlib import Path

manifest = plistlib.loads(Path("Dspeech/PrivacyInfo.xcprivacy").read_bytes())
required_root_keys = {
    "NSPrivacyAccessedAPITypes",
    "NSPrivacyCollectedDataTypes",
    "NSPrivacyTracking",
    "NSPrivacyTrackingDomains",
}
missing = required_root_keys - manifest.keys()
if missing:
    raise SystemExit(f"Missing root keys: {sorted(missing)}")
if manifest["NSPrivacyTracking"] is not False:
    raise SystemExit("NSPrivacyTracking must be false")
if manifest["NSPrivacyCollectedDataTypes"] != []:
    raise SystemExit("NSPrivacyCollectedDataTypes must be empty")
if manifest["NSPrivacyTrackingDomains"] != []:
    raise SystemExit("NSPrivacyTrackingDomains must be empty")
entries = manifest["NSPrivacyAccessedAPITypes"]
reasons = {
    reason
    for entry in entries
    if entry.get("NSPrivacyAccessedAPIType") == "NSPrivacyAccessedAPICategoryUserDefaults"
    for reason in entry.get("NSPrivacyAccessedAPITypeReasons", [])
}
if "CA92.1" not in reasons:
    raise SystemExit("Missing UserDefaults reason CA92.1")
PY

if [ "${#failures[@]}" -gt 0 ]; then
  printf 'Release readiness check failed:\n' >&2
  printf ' - %s\n' "${failures[@]}" >&2
  exit 1
fi

echo "Release readiness checks passed."
