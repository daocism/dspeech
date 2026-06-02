# Polish round — icon, F5 meter, signing, device-install prep (2026-06-02b)

Branch `feat/mvp-polish-2026-06-02` (5 commits on `feat/mvp-completion-2026-06-02` / `main`).
Build + full suite green on iPhone 17 Pro / iOS 26.4, zero warnings; device-arch compiles.

## Landed
- **App icon** — `Assets.xcassets/AppIcon` (1024px, opaque, no-alpha; cyan aviation
  broadcast-arcs on dark navy), wired via `ASSETCATALOG_COMPILER_APPICON_NAME`; actool
  compiles it into `Assets.car`.
- **Device signing** — `DEVELOPMENT_TEAM = NW2XAS56AW` (Andrei C. Personal Team, free) on
  all targets, automatic signing → headless `xcodebuild -allowProvisioningUpdates` and
  Xcode ⌘R both work without manual team picking.
- **F5 input-level meter (complete)** — `InputLevelMeter` (pure `AudioLevel.normalized`
  RMS→dB + live `AVAudioEngine` tap yielding Sendable Doubles, with a format guard so an
  invalid Simulator/no-mic input can't crash). Button-driven "Проверить уровень входа"
  (no implicit mic grab; disabled while ASR captures).
- **Translation pack indicator** — Settings surfaces `translationUnavailable`.
- **Tap-to-expand** transcript segment → timestamp + confidence (PRD main view).
- **F2** transcript already monospaced + Dynamic Type (`@ScaledMetric`), prior commit.
- **Hardening** — SimulatorSpeechProbe launch-arg gated behind `#if DEBUG`; ContentView
  `#Preview` is DEBUG-only with injected fakes (Canvas renders without AVAudioSession).
- **Dead code removed** — `AudioCaptureService` + `SpeechRecognitionService` scaffold
  protocols (unused, superseded).
- **Test isolation fix** — `SpeakerModelPackInstaller.locateModelDirectory` gained an
  injectable `cacheRoot`; the network-deny locator test no longer flakes when the real
  Simulator FluidAudio cache is populated by a prior UI download.

## Device install — how + the one remaining manual step
Canonical workflow in `docs/DEVICE-INSTALL-WORKFLOW.md`; per-function test plan in
`docs/ON-DEVICE-TEST-CHECKLIST.md`; one-command loop `scripts/run-on-device.sh`.
**Blocker (user-only):** the paired iPhone 17 Pro Max has `developerModeStatus: disabled`.
Enable Settings → Privacy & Security → **Developer Mode** → On → restart → trust. Then
`./scripts/run-on-device.sh` (or Xcode ⌘R) installs over USB/Wi-Fi. Free Personal Team =
7-day cert (rebuild to refresh); no TestFlight without the paid program.

## PRD status
F1 ✓, F2 ✓, F3 ✓ (translation), F4 ✓, F5 ✓ (picker + persistence + meter), F8 ✓, §3 ✓.
F6/F7 are device-only (60-min crash-free / battery — verify on the phone). For App Store
submission (not personal install): ADR-0008 network-deny/replay kit + ASC metadata + paid
program + repo sign-off still required.
