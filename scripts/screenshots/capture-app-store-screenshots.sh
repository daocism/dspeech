#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_PATH="${ROOT_DIR}/Dspeech.xcodeproj"
SCHEME="${DSPEECH_SCREENSHOT_SCHEME:-Dspeech}"
BUNDLE_ID="${DSPEECH_SCREENSHOT_BUNDLE_ID:-com.dspeech.app}"
CONFIGURATION="${DSPEECH_SCREENSHOT_CONFIGURATION:-Debug}"
DATE_STAMP="${DSPEECH_SCREENSHOT_DATE:-$(date +%Y-%m-%d)}"
OUTPUT_ROOT="${ROOT_DIR}/tmp/app-store-screenshots/${DATE_STAMP}"
DERIVED_DATA="${DSPEECH_SCREENSHOT_DERIVED_DATA:-${ROOT_DIR}/tmp/app-store-screenshots-derived-data}"
APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}-iphonesimulator/Dspeech.app"
PACKAGE_RESOLVED="${ROOT_DIR}/Dspeech.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

# xcodebuild and simctl both require a full Xcode; when the active developer dir
# has drifted to the Command Line Tools instance (common after an OS/CLT update)
# they abort with "requires Xcode". Resolve a full Xcode via DEVELOPER_DIR without
# sudo so screenshot regeneration is self-healing. Mirrors build-unsigned-archive.sh.
if command -v xcodebuild >/dev/null 2>&1 && ! xcodebuild -version >/dev/null 2>&1; then
  for candidate in \
    "${DEVELOPER_DIR:-}" \
    /Applications/Xcode.app/Contents/Developer \
    /Applications/Xcode-beta.app/Contents/Developer; do
    [ -n "$candidate" ] || continue
    if DEVELOPER_DIR="$candidate" xcodebuild -version >/dev/null 2>&1; then
      export DEVELOPER_DIR="$candidate"
      echo "DEVELOPER_DIR=$DEVELOPER_DIR (auto-resolved; active xcode-select dir lacks a full Xcode)"
      break
    fi
  done
fi

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

booted_runtime() {
  xcrun simctl list runtimes available -j \
    | ruby -rjson -e '
      data = JSON.parse(STDIN.read)
      runtime = data.fetch("runtimes").select { |r|
        r["isAvailable"] && r["identifier"].to_s.include?("iOS")
      }.max_by { |r| r["version"].to_s.split(".").map(&:to_i) }
      abort("No available iOS simulator runtime found") unless runtime
      puts runtime.fetch("identifier")
    '
}

device_type_id_for_name() {
  local name="$1"
  xcrun simctl list devicetypes -j \
    | ruby -rjson -e '
      name = ARGV.fetch(0)
      data = JSON.parse(STDIN.read)
      match = data.fetch("devicetypes").find { |d| d["name"] == name }
      puts match["identifier"] if match
    ' "$name"
}

device_udid_for_name() {
  local name="$1"
  xcrun simctl list devices available -j \
    | ruby -rjson -e '
      name = ARGV.fetch(0)
      data = JSON.parse(STDIN.read)
      data.fetch("devices").each_value do |devices|
        match = devices.find { |d| d["isAvailable"] && d["name"] == name }
        if match
          puts match.fetch("udid")
          exit 0
        end
      end
    ' "$name"
}

device_state_for_udid() {
  local udid="$1"
  xcrun simctl list devices available -j \
    | ruby -rjson -e '
      udid = ARGV.fetch(0)
      data = JSON.parse(STDIN.read)
      data.fetch("devices").each_value do |devices|
        match = devices.find { |d| d["udid"] == udid }
        if match
          puts match.fetch("state", "")
          exit 0
        end
      end
    ' "$udid"
}

local_swift_package_checkout_name_sets() {
  if [[ ! -f "$PACKAGE_RESOLVED" ]]; then
    return 0
  fi

  ruby -rjson -e '
    data = JSON.parse(File.read(ARGV.fetch(0)))
    data.fetch("pins").each do |pin|
      location = pin.fetch("location", "")
      basename = File.basename(location.sub(/\.git\z/, ""))
      puts [pin.fetch("identity"), basename].compact.uniq.join("|")
    end
  ' "$PACKAGE_RESOLVED"
}

require_local_swift_package_checkouts() {
  local checkout_root="${DERIVED_DATA}/SourcePackages/checkouts"
  local missing=()
  local line identity basename

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    IFS="|" read -r identity basename <<<"$line"
    if [[ ! -d "${checkout_root}/${identity}" && ! -d "${checkout_root}/${basename}" ]]; then
      missing+=("${identity}/${basename}")
    fi
  done < <(local_swift_package_checkout_name_sets)

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return 0
  fi

  cat >&2 <<EOF
Missing local SwiftPM checkout(s) in ${checkout_root}: ${missing[*]}
This screenshot script is no-outbound by default. Seed package checkouts before
running it, or set DSPEECH_SCREENSHOT_DERIVED_DATA to an existing DerivedData
folder that already contains SourcePackages/checkouts.
EOF
  exit 1
}

find_or_create_device() {
  local key="$1"
  shift

  local override_var="DSPEECH_SCREENSHOT_${key}_UDID"
  if [[ -n "${!override_var:-}" ]]; then
    echo "${!override_var}"
    return 0
  fi

  local runtime_id
  runtime_id="$(booted_runtime)"

  local candidate desired_name udid device_type_id
  for candidate in "$@"; do
    desired_name="Dspeech ${candidate}"
    udid="$(device_udid_for_name "$desired_name")"
    if [[ -n "$udid" ]]; then
      echo "$udid"
      return 0
    fi

    device_type_id="$(device_type_id_for_name "$candidate")"
    if [[ -n "$device_type_id" ]]; then
      xcrun simctl create "$desired_name" "$device_type_id" "$runtime_id"
      return 0
    fi
  done

  echo "No available simulator or device type found for ${key}: $*" >&2
  exit 1
}

ensure_booted() {
  local udid="$1"
  if [[ "$(device_state_for_udid "$udid")" == "Booted" ]]; then
    return 0
  fi

  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || {
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
  }
}

build_app() {
  mkdir -p "$OUTPUT_ROOT"
  mkdir -p "$DERIVED_DATA"
  require_local_swift_package_checkouts
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$DERIVED_DATA" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackageUpdates \
    CODE_SIGNING_ALLOWED=NO \
    build
}

install_and_launch() {
  local udid="$1"
  xcrun simctl uninstall "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$udid" "$APP_PATH"
  xcrun simctl privacy "$udid" grant microphone "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl privacy "$udid" grant speech-recognition "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch \
    "$udid" \
    "$BUNDLE_ID" \
    -dspeech.privacy.mode.v1 localOnly \
    -dspeech.voicefilter.modelpack.v1 absent \
    -dspeech.onboarding.completed.v1 true \
    >/dev/null
}

validate_dimensions() {
  local file="$1"
  local accepted_dimensions="$2"

  if ! command -v sips >/dev/null 2>&1; then
    return 0
  fi

  local width height actual
  width="$(sips -g pixelWidth "$file" | awk '/pixelWidth/ {print $2}')"
  height="$(sips -g pixelHeight "$file" | awk '/pixelHeight/ {print $2}')"
  actual="${width}x${height}"

  case "|${accepted_dimensions}|" in
    *"|${actual}|"*) return 0 ;;
  esac

  echo "Unexpected screenshot size for ${file}: ${actual}; accepted: ${accepted_dimensions}" >&2
  exit 1
}

capture_profile() {
  local profile="$1"
  local udid="$2"
  local accepted_dimensions="$3"
  local out_dir="${OUTPUT_ROOT}/${profile}"
  local out_file="${out_dir}/01-cockpit-local-empty.png"

  mkdir -p "$out_dir"
  ensure_booted "$udid"
  install_and_launch "$udid"
  # why: on a cold simulator the launch zoom animation is still mid-flight when the
  # screenshot fires, capturing a white launch frame instead of the cockpit (caught by
  # the 2026-07-02 full-frame review). Settle before shooting.
  sleep "${DSPEECH_SCREENSHOT_SETTLE_SECONDS:-8}"
  xcrun simctl io "$udid" screenshot --type=png "$out_file" >/dev/null
  validate_dimensions "$out_file" "$accepted_dimensions"
  echo "$out_file"
}

main() {
  require_tool xcrun
  require_tool xcodebuild
  require_tool ruby

  local iphone_67 iphone_65 ipad_13 ipad_129
  iphone_67="$(find_or_create_device IPHONE_67 \
    "iPhone 17 Pro Max" \
    "iPhone 16 Pro Max" \
    "iPhone 15 Pro Max" \
    "iPhone 14 Pro Max" \
    "iPhone 13 Pro Max")"
  iphone_65="$(find_or_create_device IPHONE_65 \
    "iPhone 11 Pro Max" \
    "iPhone XS Max")"
  ipad_13="$(find_or_create_device IPAD_13 \
    "iPad Pro 13-inch (M5)" \
    "iPad Pro 13-inch (M4)" \
    "iPad Pro (13-inch) (M4)")"
  ipad_129="$(find_or_create_device IPAD_129 \
    "iPad Pro (12.9-inch) (6th generation)" \
    "iPad Pro (12.9-inch) (5th generation)" \
    "iPad Pro (12.9-inch) (4th generation)" \
    "iPad Pro (12.9-inch) (3rd generation)" \
    "iPad Pro (12.9-inch) (2nd generation)")"

  build_app
  capture_profile iphone-67 "$iphone_67" "1320x2868|1290x2796|1260x2736"
  capture_profile iphone-65 "$iphone_65" "1284x2778|1242x2688"
  capture_profile ipad-13 "$ipad_13" "2064x2752|2048x2732"
  capture_profile ipad-129 "$ipad_129" "2048x2732"
}

main "$@"
