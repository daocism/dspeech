#!/usr/bin/env bash
set -euo pipefail

best_bundle=""
best_version=""

version_gt() {
  awk -v left="$1" -v right="$2" '
    BEGIN {
      split(left, left_parts, ".")
      split(right, right_parts, ".")
      for (part_index = 1; part_index <= 6; part_index++) {
        left_value = left_parts[part_index] + 0
        right_value = right_parts[part_index] + 0
        if (left_value > right_value) {
          exit 0
        }
        if (left_value < right_value) {
          exit 1
        }
      }
      exit 1
    }
  '
}

for candidate in /Applications/Xcode_26*.app /Applications/Xcode.app; do
  if [ ! -d "$candidate" ]; then
    continue
  fi

  xcodebuild_bin="$candidate/Contents/Developer/usr/bin/xcodebuild"
  if [ ! -x "$xcodebuild_bin" ]; then
    continue
  fi

  version="$("$xcodebuild_bin" -version | awk '/^Xcode / { version=$2 } END { if (version != "") print version }')"
  case "${version:-}" in
    26*)
      if [ -z "$best_version" ] || version_gt "$version" "$best_version"; then
        best_version="$version"
        best_bundle="$candidate"
      fi
      ;;
  esac
done

if [ -z "$best_bundle" ]; then
  echo "No Xcode 26 app bundle found. Expected /Applications/Xcode_26*.app or /Applications/Xcode.app with Xcode 26." >&2
  exit 1
fi

developer_dir="$best_bundle/Contents/Developer"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "DEVELOPER_DIR=$developer_dir" >> "$GITHUB_ENV"
else
  echo "export DEVELOPER_DIR=$developer_dir"
fi

DEVELOPER_DIR="$developer_dir" "$developer_dir/usr/bin/xcodebuild" -version
