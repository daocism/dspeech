#!/usr/bin/env bash
# One-command: build Dspeech, install on the connected iPhone, and (re)launch it.
# Free Personal Team signing → the dev cert lapses after 7 days; just rerun this.
# Requires (one-time on the phone): Developer Mode ON, "Trust This Computer", paired,
# and — on the very first install — trust the developer cert under Settings → General →
# VPN & Device Management.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."

SCHEME="Dspeech"
BUNDLE_ID="com.dspeech.app"
DERIVED="build/device"

echo "▸ Resolving connected iPhone…"
# xcodebuild build-destination id (hardware UDID) — must target a SPECIFIC device so a
# free Personal Team registers it and -allowProvisioningUpdates can mint a profile.
BUILD_ID=$(
  xcodebuild -showdestinations -project Dspeech.xcodeproj -scheme "$SCHEME" 2>/dev/null \
    | grep -E 'platform:iOS,' | grep -viE 'Simulator|placeholder' \
    | grep -oE 'id:[0-9A-Fa-f-]+' | head -1 | cut -d: -f2
)
# devicectl install id (CoreDevice identifier — different from the build UDID)
xcrun devicectl list devices --json-output /tmp/dspeech-devices.json >/dev/null 2>&1 || true
INSTALL_ID=$(python3 - <<'PY'
import json
try:
    d = json.load(open("/tmp/dspeech-devices.json"))
    for dev in d.get("result", {}).get("devices", []):
        name = (dev.get("deviceProperties", {}) or {}).get("name", "") or ""
        paired = (dev.get("connectionProperties", {}) or {}).get("pairingState") == "paired"
        if paired and "iPhone" in name:
            print(dev.get("identifier", "")); break
except Exception:
    pass
PY
)
rm -f /tmp/dspeech-devices.json

if [ -z "$BUILD_ID" ] || [ -z "$INSTALL_ID" ]; then
  echo "✗ No connected iPhone found. Plug in a data cable, unlock, tap Trust, and enable"
  echo "  Developer Mode (Settings → Privacy & Security → Developer Mode)."
  exit 1
fi

echo "▸ Building + signing for device ${BUILD_ID}…"
xcodebuild -project Dspeech.xcodeproj -scheme "$SCHEME" -configuration Debug \
  -destination "platform=iOS,id=$BUILD_ID" \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates build

APP="$DERIVED/Build/Products/Debug-iphoneos/${SCHEME}.app"
[ -d "$APP" ] || { echo "✗ Build product not found at $APP"; exit 1; }

echo "▸ Installing to ${INSTALL_ID}…"
xcrun devicectl device install app --device "$INSTALL_ID" "$APP"

echo "▸ Launching…"
if ! xcrun devicectl device process launch --terminate-existing --device "$INSTALL_ID" "$BUNDLE_ID"; then
  echo "⚠ Installed, but launch was denied — on the FIRST install you must trust the cert:"
  echo "  iPhone → Settings → General → VPN & Device Management → Apple Development → Trust."
  echo "  Then tap the Dspeech icon, or rerun this script."
  exit 0
fi
echo "✓ Dspeech is running on your iPhone."
