#!/usr/bin/env bash
set -euo pipefail

# One-command local full gate: format lint -> device-arch compile -> full unit
# + core UI suite. This is the authoritative pre-merge gate (hosted CI UI lanes
# are documented CPU-starvation flake territory; local mac24 is the truth).
#
# Usage: scripts/local-gate.sh [--unit-only]

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR="$developer_dir"

unit_only=0
if [ "${1:-}" = "--unit-only" ]; then
  unit_only=1
fi

echo "== gate 1/4: swift format lint (strict)"
swift_format="$(xcrun --find swift-format)"
"$swift_format" lint --strict --recursive Dspeech DspeechTests DspeechUITests

echo "== gate 2/4: device-arch compile (generic/platform=iOS)"
xcodebuild \
  -project Dspeech.xcodeproj \
  -scheme Dspeech \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  -quiet build

echo "== gate 3/4: unit suite (DspeechTests)"
xcodebuild \
  -project Dspeech.xcodeproj \
  -scheme Dspeech \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -testPlan Dspeech \
  -only-testing:DspeechTests \
  -quiet test

if [ "$unit_only" = "1" ]; then
  echo "== gate 4/4: SKIPPED (--unit-only)"
  echo "local gate: PASS (unit-only)"
  exit 0
fi

echo "== gate 4/4: core UI suite (DspeechUITests, default test plan)"
xcodebuild \
  -project Dspeech.xcodeproj \
  -scheme Dspeech \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -testPlan Dspeech \
  -only-testing:DspeechUITests \
  -quiet test

echo "local gate: PASS"
