#!/usr/bin/env bash
# One-command: build Dspeech, install on the connected iPhone, and (re)launch it.
# Free Personal Team signing → the dev cert lapses after 7 days; just rerun this.
# Requires (one-time on the phone): Developer Mode ON, "Trust This Computer", paired.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."

SCHEME="Dspeech"
BUNDLE_ID="com.dspeech.app"
DERIVED="build/device"

echo "▸ Building (device, automatic signing)…"
xcodebuild -project Dspeech.xcodeproj -scheme "$SCHEME" \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates build

APP="$DERIVED/Build/Products/Debug-iphoneos/${SCHEME}.app"
[ -d "$APP" ] || { echo "✗ Build product not found at $APP"; exit 1; }

echo "▸ Resolving connected iPhone…"
xcrun devicectl list devices --json-output /tmp/dspeech-devices.json >/dev/null 2>&1 || true
DEVICE_ID=$(python3 - <<'PY'
import json
try:
    d = json.load(open("/tmp/dspeech-devices.json"))
    for dev in d.get("result", {}).get("devices", []):
        name = (dev.get("deviceProperties", {}) or {}).get("name", "") or ""
        paired = (dev.get("connectionProperties", {}) or {}).get("pairingState") == "paired"
        if paired and "iPhone" in name:
            print(dev.get("identifier", ""))
            break
except Exception:
    pass
PY
)
rm -f /tmp/dspeech-devices.json

if [ -z "$DEVICE_ID" ]; then
  echo "✗ No paired iPhone found."
  echo "  Connect it, unlock, tap 'Trust', and enable Developer Mode:"
  echo "  Settings → Privacy & Security → Developer Mode → On → restart."
  exit 1
fi

echo "▸ Installing to $DEVICE_ID…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"

echo "▸ Launching…"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE_ID" "$BUNDLE_ID"

echo "✓ Dspeech is on your iPhone."
