# Dspeech — device install & iterate workflow (how pros do it)

Canonical 2026 (Xcode 26 / iOS 26) solo-dev workflow for: build → put on your iPhone →
test → tweak → reinstall. Two tiers — pick by whether you have a paid Apple Developer
Program.

## One-time iPhone setup (required for ALL local installs)
1. Connect the iPhone by a **data** cable, unlock it, tap **Trust This Computer** +
   passcode. (If `devicectl list devices` shows `transport: None`, the data link isn't
   live — charge-only cable, locked phone, or Trust not granted.)
2. **Reveal + enable Developer Mode.** On iOS 16+ (incl. iOS 26) the Developer Mode row is
   **hidden** in Settings → Privacy & Security until the Mac talks to the device. Surface it:
   open **Xcode → Window → Devices and Simulators (⇧⌘2)** and select the iPhone (Xcode
   shows "Developer Mode disabled" and prepares the device) — or just attempt an install
   (`./scripts/run-on-device.sh` / ⌘R). NOW Settings → Privacy & Security → **Developer
   Mode** appears → On → Restart → after reboot tap "Turn On" + passcode. (NOT needed for
   TestFlight builds, NOT on the Simulator.) Until it's on, the device reads
   `developerModeStatus: disabled` / `unavailable` to Xcode and `devicectl`.
3. Apple ID is already added in Xcode → Settings → Accounts (Personal Team `NW2XAS56AW`).
   The project is set to automatic signing with that team, so no per-build team picking.

## Tier 1 — Free Apple ID (what you have now): Xcode cable / Wi-Fi
The everyday loop. No cost. Caveat: the dev cert **expires after 7 days** (app stops
launching — just rebuild to refresh), max **3** sideloaded dev apps per device, ≤10 new
App IDs per 7 days. **No TestFlight** on a free account.

- **GUI (simplest):** pick the iPhone in Xcode's run-destination dropdown → **⌘R**. Xcode
  builds, installs (USB or Wi-Fi), launches, attaches the console. ⌘. to stop, ⌘R again.
- **Untethered:** Xcode → Window → Devices and Simulators → select device → tick
  **Connect via network** (once, over cable). Then ⌘R works over Wi-Fi with no cable.
- **One command (no Xcode window):** `./scripts/run-on-device.sh` — does
  `xcodebuild -allowProvisioningUpdates build` → `xcrun devicectl device install app` →
  `xcrun devicectl device process launch --terminate-existing`. This is the modern path
  (`ios-deploy`/`instruments` are dead on iOS 17+). Rerun it to update the app on the phone.

## Tier 2 — Paid Apple Developer Program ($99/yr): TestFlight (OTA, no cable)
Worth it when you want over-the-air updates / to test off your desk / share with others.
1. Register the bundle id + create an App Store Connect (ASC) app record.
2. Create an **Internal Testing** group, add yourself as an internal tester.
3. Archive + upload; internal testing **skips Beta App Review** → installable via the
   **TestFlight** app within minutes of ASC "Processing" finishing. Bump the build number,
   re-upload → the new build appears OTA (auto-update toggle per app in TestFlight).
   - Xcode: Product → Archive → Organizer → Distribute → **TestFlight Internal Only**.
   - CLI: `xcodebuild archive -scheme Dspeech -archivePath build/Dspeech.xcarchive
     -destination 'generic/platform=iOS' -allowProvisioningUpdates` →
     `xcodebuild -exportArchive -archivePath build/Dspeech.xcarchive
     -exportOptionsPlist ExportOptions.plist -exportPath build/export` →
     `xcrun altool --upload-app -f build/export/Dspeech.ipa -t ios --apiKey <KEY> --apiIssuer <ISSUER>`.

## Pro automation (when you outgrow ⌘R): fastlane + ASC API key
The 2026 indie default. An **App Store Connect API key (.p8)** kills 2FA prompts (JWT auth);
fastlane wraps build + upload into two lanes:
- `fastlane device` — build (development export) + install to the connected iPhone.
- `fastlane beta` — build (app-store export) + upload to TestFlight via `pilot`.
Setup: `brew install fastlane`, `fastlane init`, create a **Team** ASC API key (App Manager
role) and reference its `.p8` via `api_key_path`. Gotchas: download the `.p8` exactly once;
the JWT `duration` ≤ 1200 s; `match` (cert/profile in a private git repo) only if you have
>1 Mac — a single-machine solo dev can stay on Xcode automatic signing.

## Recommendation for Dspeech right now
Stay on **Tier 1** (free): `./scripts/run-on-device.sh` or ⌘R over Wi-Fi for the
build→test→tweak→reinstall loop. Move to **Tier 2 / fastlane** only if/when you want
OTA TestFlight updates or to hand the app to other testers — that needs the paid program
and the no-CIS / no-App-Store-ops sign-off in CLAUDE.md.
