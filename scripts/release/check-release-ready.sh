#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

failures=()
warnings=()
screenshot_max_age_seconds=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --max-age)
      shift
      if [ -z "${1:-}" ] || ! [[ "$1" =~ ^[0-9]+$ ]]; then
        echo "Usage: scripts/release/check-release-ready.sh [--max-age seconds]" >&2
        exit 2
      fi
      screenshot_max_age_seconds="$1"
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: scripts/release/check-release-ready.sh [--max-age seconds]" >&2
      exit 2
      ;;
  esac
  shift
done

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

unix_time_for_file() {
  local path="$1"
  if [ "$(uname -s)" = "Darwin" ]; then
    stat -f %m "$path"
  else
    stat -c %Y "$path"
  fi
}

format_unix_time() {
  local timestamp="$1"
  if date -r "$timestamp" "+%Y-%m-%d %H:%M:%S %z" >/dev/null 2>&1; then
    date -r "$timestamp" "+%Y-%m-%d %H:%M:%S %z"
  elif date -d "@$timestamp" "+%Y-%m-%d %H:%M:%S %z" >/dev/null 2>&1; then
    date -d "@$timestamp" "+%Y-%m-%d %H:%M:%S %z"
  else
    printf '@%s' "$timestamp"
  fi
}

require_fresh_screenshots() {
  local screenshot_root="tmp/app-store-screenshots"
  local reference_timestamp
  local reference_description

  if [ -n "$screenshot_max_age_seconds" ]; then
    reference_timestamp="$(($(date +%s) - screenshot_max_age_seconds))"
    reference_description="max age ${screenshot_max_age_seconds}s"
  else
    if ! reference_timestamp="$(git log -1 --format=%ct HEAD 2>/dev/null)"; then
      failures+=("cannot determine HEAD timestamp for screenshot freshness check")
      return
    fi
    reference_description="HEAD commit timestamp $(format_unix_time "$reference_timestamp")"
  fi

  if [ ! -d "$screenshot_root" ]; then
    failures+=("missing captured App Store screenshots under ${screenshot_root}/")
    return
  fi

  local found=0
  local stale=()
  local screenshot_path
  local screenshot_timestamp
  while IFS= read -r -d '' screenshot_path; do
    found=1
    screenshot_timestamp="$(unix_time_for_file "$screenshot_path")"
    if [ "$screenshot_timestamp" -le "$reference_timestamp" ]; then
      stale+=("${screenshot_path} ($(format_unix_time "$screenshot_timestamp"))")
    fi
  done < <(find "$screenshot_root" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -print0)

  if [ "$found" -eq 0 ]; then
    failures+=("missing captured App Store screenshots under ${screenshot_root}/")
  elif [ "${#stale[@]}" -gt 0 ]; then
    failures+=("stale App Store screenshots: regenerate with scripts/screenshots/capture-app-store-screenshots.sh after ${reference_description}; stale files: ${stale[*]}")
  fi
}

require_file ".github/workflows/ci.yml"
require_file ".githooks/pre-commit"
require_file ".githooks/commit-msg"
require_file "scripts/install-githooks.sh"
require_file "scripts/release/build-unsigned-archive.sh"
require_file "scripts/release/check-release-policy.py"
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
require_grep "macos-26" ".github/workflows/ci.yml" "CI must use macos-26 for iOS 26.4-ish simulator"
require_grep "select-ios-simulator.sh" ".github/workflows/ci.yml" "CI must select the iOS 26 simulator via scripts/ci/select-ios-simulator.sh"
require_grep "swift format lint --strict --recursive" ".github/workflows/ci.yml" "CI must run strict swift format lint"
require_grep "gitleaks git --redact --verbose" ".github/workflows/ci.yml" "CI must run gitleaks with redaction"
require_grep "fetch-depth: 0" ".github/workflows/ci.yml" "Gitleaks action checkout must use full history"
require_grep "NSPrivacyAccessedAPICategoryUserDefaults" "Dspeech/PrivacyInfo.xcprivacy" "Privacy manifest must declare UserDefaults required-reason API"
require_grep "CA92\\.1" "Dspeech/PrivacyInfo.xcprivacy" "Privacy manifest must include UserDefaults reason CA92.1"
require_grep "NSPrivacyTracking" "Dspeech/PrivacyInfo.xcprivacy" "Privacy manifest must declare tracking flag"
require_grep "PrivacyInfo\\.xcprivacy in Resources" "Dspeech.xcodeproj/project.pbxproj" "Privacy manifest must be included as app target resource"
require_grep "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO" "Dspeech.xcodeproj/project.pbxproj" "Export compliance Info.plist key must be set to NO"
require_grep "^#if DEBUG" "Dspeech/App/SimulatorSpeechProbe.swift" "Simulator speech probe (incl. server-fallback path) must be DEBUG-gated out of release builds"
require_grep "CODE_SIGNING_ALLOWED=NO" "scripts/release/build-unsigned-archive.sh" "Unsigned archive script must disable code signing"
if ! python3 scripts/release/check-release-policy.py --source-only; then
  failures+=("release source policy failed")
fi
require_grep "tmp/release/Dspeech\\.xcarchive" "scripts/release/build-unsigned-archive.sh" "Unsigned archive output path must be tmp/release/Dspeech.xcarchive"
# why: BUILD a fresh unsigned archive and validate IT — never a stale tmp/ artifact. A
# stale archive previously let "release ready" pass while the source tree had moved on.
# DSPEECH_SKIP_ARCHIVE=1 is for fast doc-only runs and records a loud warning so a skipped
# build can never be mistaken for a verified one.
archive_path="tmp/release/Dspeech.xcarchive"
app_binary="$archive_path/Products/Applications/Dspeech.app/Dspeech"
release_policy_stamp="$archive_path.dspeech-build-stamp.json"
release_archive_log="tmp/release-archive-build.log"
if [ "${DSPEECH_SKIP_ARCHIVE:-0}" = "1" ]; then
  warnings+=("archive build SKIPPED (DSPEECH_SKIP_ARCHIVE=1) — unsigned readiness NOT freshly verified")
elif [ "$(uname -s)" = "Darwin" ] && command -v xcodebuild >/dev/null 2>&1; then
  echo "Building fresh unsigned archive for release readiness check..."
  mkdir -p "$(dirname "$release_archive_log")"
  if ! scripts/release/build-unsigned-archive.sh >"$release_archive_log" 2>&1; then
    failures+=("fresh unsigned archive build failed (see $release_archive_log)")
  fi
else
  failures+=("cannot build unsigned archive: xcodebuild unavailable on this host")
fi

if [ ! -d "$archive_path/Products" ] || [ ! -f "$archive_path/Info.plist" ]; then
  failures+=("unsigned archive missing or incomplete: $archive_path")
elif [ ! -f "$app_binary" ]; then
  failures+=("release app binary not found in archive: $app_binary")
else
  # [#1] the simulator speech probe (and its requiresOnDeviceRecognition:false server
  # fallback) must not exist in a Release binary. A Release binary is partially stripped so
  # `nm` misses Swift symbols; scan for the probe's unique DEBUG-only string literals instead
  # — they survive stripping and only appear if SimulatorSpeechProbe.swift compiled in. Guard
  # against a false pass by first asserting `strings` can see a literal that is ALWAYS present.
  # grep -cF (not -qF): grep -q closes the pipe on first match, strings then dies with
  # SIGPIPE, and `set -o pipefail` propagates that as a non-zero pipeline status — turning a
  # PRESENT sentinel into a false "absent". Counting reads the whole stream so strings exits
  # cleanly; `|| true` keeps a legitimate zero-match (grep -c exit 1) from tripping set -e.
  sentinel_hits="$(strings -a "$app_binary" 2>/dev/null | grep -cF "FluidInference/speaker-diarization-coreml" || true)"
  if [ "${sentinel_hits:-0}" -eq 0 ]; then
    failures+=("release binary string scan unreliable (sentinel literal absent) — cannot verify probe exclusion")
  else
    probe_markers="$(strings -a "$app_binary" 2>/dev/null \
      | grep -E "sfspeech-probe-result|dspeech-sfspeech-probe|Dspeech Speech Probe" || true)"
    if [ -n "$probe_markers" ]; then
      failures+=("speech-probe string literals present in the RELEASE binary — probe leaked past #if DEBUG")
    fi
  fi
fi

if [ -d "$archive_path" ]; then
  if ! python3 scripts/release/check-release-policy.py --archive "$archive_path" --stamp "$release_policy_stamp"; then
    failures+=("release archive policy failed")
  fi
fi
signing_refs=(
  "op://MyInfra-Active/dspeech-apple-distribution-certificate/credential"
  "op://MyInfra-Active/dspeech-apple-distribution-certificate-password/credential"
  "op://MyInfra-Active/dspeech-app-store-provisioning-profile/credential"
  "op://MyInfra-Active/dspeech-app-store-connect-api-key/credential"
  "op://MyInfra-Active/dspeech-app-store-connect-api-key-id/credential"
  "op://MyInfra-Active/dspeech-app-store-connect-issuer-id/credential"
)
for op_ref in "${signing_refs[@]}"; do
  require_grep "$op_ref" "docs/release/signed-build-runbook.md" "Runbook must use op:// signing and ASC references"
  require_grep "$op_ref" "docs/product/app-store/testflight-setup.md" "TestFlight worksheet must use op:// signing and ASC references"
done

# Validate the ACTUAL signing/ASC secrets, not just that the runbook names them. Signed /
# TestFlight distribution stays blocked until all are present (CLAUDE.md hard rule 6); report
# the real state so an unsigned-only pass never masquerades as full release readiness.
signing_present=0
signing_missing=()
signing_checked=0
signing_ready=0
if command -v op >/dev/null 2>&1 && op whoami >/dev/null 2>&1; then
  signing_checked=1
  for ref in "${signing_refs[@]}"; do
    if op read "$ref" >/dev/null 2>&1; then
      signing_present=$((signing_present + 1))
    else
      signing_missing+=("$ref")
    fi
  done
  if [ "${#signing_missing[@]}" -eq 0 ]; then
    signing_ready=1
  fi
else
  warnings+=("signing/ASC secret validation skipped — op CLI unavailable or not signed in")
fi

# Opt-in hard gate for when a signed build is actually being prepared.
if [ "${DSPEECH_REQUIRE_SIGNING:-0}" = "1" ] && [ "$signing_ready" != "1" ]; then
  failures+=("signed/TestFlight prerequisites not met: ${#signing_missing[@]}/6 signing/ASC secret(s) missing")
fi
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

require_fresh_screenshots

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

if [ "${#warnings[@]}" -gt 0 ]; then
  printf 'Warnings:\n'
  printf ' - %s\n' "${warnings[@]}"
fi

if [ "${#failures[@]}" -gt 0 ]; then
  printf 'Release readiness check failed:\n' >&2
  printf ' - %s\n' "${failures[@]}" >&2
  exit 1
fi

if [ "$signing_ready" = "1" ]; then
  echo "Signed/TestFlight prerequisites: READY (6/6 signing+ASC secrets present)."
elif [ "$signing_checked" = "1" ]; then
  echo "Signed/TestFlight prerequisites: NOT READY (${signing_present}/6 secrets present) — unsigned archive only, not submittable."
else
  echo "Signed/TestFlight prerequisites: UNVERIFIED (op unavailable)."
fi

echo "Unsigned release-readiness checks passed (fresh archive built and validated)."
