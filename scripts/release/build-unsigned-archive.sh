#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

archive_path="$repo_root/tmp/release/Dspeech.xcarchive"
project="Dspeech.xcodeproj"
scheme="Dspeech"

read_build_setting() {
  local key="$1"
  xcodebuild -project "$project" -scheme "$scheme" -showBuildSettings 2>/dev/null \
    | awk -F'= ' -v key="$key" '$1 ~ key" *$" { value=$2 } END { if (value != "") print value }'
}

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required to produce an unsigned archive." >&2
  exit 1
fi

# A full Xcode is required for `xcodebuild archive`. When the active developer
# directory has drifted to the Command Line Tools instance (common after an OS
# or CLT update), `xcodebuild` aborts with "requires Xcode". Resolve a full
# Xcode via DEVELOPER_DIR without needing sudo `xcode-select -s`, and fail loudly
# if none is available instead of letting an empty build setting abort silently.
if ! xcodebuild -version >/dev/null 2>&1; then
  resolved=""
  for candidate in \
    "${DEVELOPER_DIR:-}" \
    /Applications/Xcode.app/Contents/Developer \
    /Applications/Xcode-beta.app/Contents/Developer; do
    [ -n "$candidate" ] || continue
    if DEVELOPER_DIR="$candidate" xcodebuild -version >/dev/null 2>&1; then
      resolved="$candidate"
      break
    fi
  done
  if [ -z "$resolved" ]; then
    echo "xcodebuild cannot run: active developer dir is '$(xcode-select -p 2>/dev/null || echo unknown)'." >&2
    echo "Install a full Xcode and select it via 'sudo xcode-select -s /Applications/Xcode.app/Contents/Developer' or set DEVELOPER_DIR." >&2
    exit 1
  fi
  export DEVELOPER_DIR="$resolved"
  echo "DEVELOPER_DIR=$DEVELOPER_DIR (auto-resolved; active xcode-select dir lacks a full Xcode)"
fi

marketing_version="$(read_build_setting MARKETING_VERSION)"
build_number="$(read_build_setting CURRENT_PROJECT_VERSION)"

if [ -z "$marketing_version" ] || [ -z "$build_number" ]; then
  echo "Could not read MARKETING_VERSION or CURRENT_PROJECT_VERSION." >&2
  exit 1
fi

echo "MARKETING_VERSION=$marketing_version"
echo "CURRENT_PROJECT_VERSION=$build_number"

rm -rf "$archive_path"
mkdir -p "$(dirname "$archive_path")"

xcodebuild archive \
  -project "$project" \
  -scheme "$scheme" \
  -configuration Release \
  -destination generic/platform=iOS \
  -archivePath "$archive_path" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""

echo "Unsigned archive created at $archive_path"
