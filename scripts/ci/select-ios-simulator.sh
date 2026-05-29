#!/usr/bin/env bash
set -euo pipefail

device_name="iPhone 17 Pro"
best_runtime=""

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

runtimes="$(
  xcrun simctl list devices available | awk -v device="$device_name" '
    /^-- iOS 26([.]| )/ {
      runtime = $3
      next
    }
    /^-- / {
      runtime = ""
      next
    }
    runtime != "" && index($0, device " (") > 0 {
      print runtime
    }
  '
)"

for runtime in $runtimes; do
  if [ -z "$best_runtime" ] || version_gt "$runtime" "$best_runtime"; then
    best_runtime="$runtime"
  fi
done

if [ -z "$best_runtime" ]; then
  echo "No available $device_name iOS 26.x simulator found for the selected Xcode." >&2
  xcrun simctl list devices available >&2
  exit 1
fi

destination="platform=iOS Simulator,name=$device_name,OS=$best_runtime"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "SIMULATOR_DESTINATION=$destination" >> "$GITHUB_ENV"
else
  echo "export SIMULATOR_DESTINATION='$destination'"
fi

echo "Selected simulator destination: $destination"
