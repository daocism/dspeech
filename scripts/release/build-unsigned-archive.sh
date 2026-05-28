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
