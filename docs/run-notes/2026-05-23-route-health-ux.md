# Route-health UX increment — reviewer handoff (2026-05-23)

Run: `dspeech-builder-20260523T190026Z-8ff9dfb0`
Role: `reviewer`
Branch: `feat/local-pilot-voice-filter`
PR: [#2](https://github.com/daocism/dspeech/pull/2) (OPEN, draft)
Notion `369dfa2b-7893-814c-be7e-e7cea26486a6`: **NOT_FOUND** in this environment — status recorded here instead.

## Verdict: REQUEST_CHANGES — backend shippable, UX slice not delivered

The route-health **model + monitor layer** is sound, isolated from AVFAudio
behind a protocol, and covered by credible green tests. But the increment was
dispatched as a **route-health *UX*** slice, and there is **no UX**: nothing in
`ContentView` or `LiveTranscriptionViewModel` consumes `RouteHealthMonitor`.
`RouteHealthMonitor` is referenced only by tests (`grep -rn RouteHealthMonitor`
→ 1 production definition, 0 production call sites, 21 test references).

As a "model + monitor layer" increment: **shippable**.
As the "route-health UX" increment named in the mission: **not shippable** —
the user-visible deliverable is absent.

## Findings

| # | Severity | Location | Issue |
|---|----------|----------|-------|
| 1 | HIGH | `Dspeech/App/ContentView.swift`, `LiveTranscriptionViewModel.swift` | No route-health surface. No start-gate, no route badge, no banner. `start()` calls `engine.start()` unconditionally — `blocksStart` is never read outside tests. |
| 2 | HIGH | `RouteHealthMonitor.swift` `bannerText` (`.lost`) | Copy promises behavior that does not exist: *"Внешний источник пропал … Запись приостановлена."* Nothing pauses capture (the monitor is not even wired). Shipping this string would be a §4 silent-failure/lie: UI claims recording paused while it keeps running on the built-in mic. Either the wiring must actually pause, or the copy must drop the "приостановлена" claim. |
| 3 | MEDIUM | `RouteHealthClassifier.swift` (`.airPlay → .suitableExternal`) | AirPlay is fundamentally an *output* transport; treating an AirPlay route input as a suitable external **capture** source is questionable for ATC audio. Team pinned it intentionally (`airPlayIsSuitableExternal_pinningCurrentBehavior`), so flagging for product confirmation, not a blocker. |
| 4 | MEDIUM | git history | Not "one focused implementation commit". All 5 route-health production Swift files + pbxproj membership landed inside `5235e0b test(audio): cover route health transitions` — production code under a `test(` type. Follow-up `e6e6083 fix(audio)` + docs commits. Impl + tests should have been separable. |
| 5 | LOW (process) | worktree provisioning | This cycle's workers (incl. this reviewer) were provisioned **MyInfra** worktrees, not dspeech worktrees, so all work landed in the shared `/home/user/projects/dspeech` checkout. Same class as prior supervisor B1 finding. Fix the provisioner before next dspeech cycle. |

## Checklist result

- [x] Route-health logic backed by `RouteHealthMonitor`/`AudioSessionRouting`, **no direct AVFAudio in SwiftUI** — but no SwiftUI consumes it yet.
- [x] `blocksStart` true for `.noInput` only (`blocksStartOnlyForNoInput`, parameterised) — **logic correct, not consumed by Start button.**
- [x] Built-in mic allowed but cautionary (`.cautionBuiltIn`, start permitted).
- [ ] **Loss of external input while listening does not silently continue — FAILS.** Monitor emits `.lost`, but capture is never paused and the monitor is not wired, so live capture *does* silently continue on the built-in mic.
- [x] Copy is confidence-aware; no flight-safety/certification claim (`displayCopyAvoidsCertifiedLanguage`, `bannerCopyAvoidsCertifiedLanguage`; forbidden: certif/guarantee/radio link/tower link/faa/easa). **Exception: finding #2 behavioral over-claim.**
- [x] No audio/transcript/network egress in this slice — route-health is pure `AVAudioSession` introspection, zero network.
- [x] Tests credible (behavior, not coincidence) and **green** — verified from a clean mac24 clone by `mrdao-autopilot-fix.md` (Debug build+test, Release build, on iPhone 17 Pro / iOS 26.4).
- [ ] **Git history is not one focused impl commit** (finding #4).

## Tests

Verified green from a clean clone (per `.ai/runs/2026-05-23-route-health/mrdao-autopilot-fix.md`):

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Dspeech.xcodeproj -scheme Dspeech \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
  CODE_SIGNING_ALLOWED=NO -quiet build test
```

- `RouteHealthClassifierTests` — pass (port classification, output-only ports,
  empty-route cases, round-trip raw values, LE+AirPlay pinned).
- `RouteHealthMonitorTests` — pass (transition→notice matrix, parameterised
  start-gate, copy guards, injected-clock determinism, start/stop idempotency).
- Release simulator build — pass.

This reviewer ran no Swift build (Linux host, no Xcode; route-health files are
in the build target — 19 pbxproj references — and were independently rebuilt
green on mac24).

## Commits on branch (vs main)

`bdef438` docs · `e6e6083` fix(audio) Swift-6 unblock · `326e719` docs ·
`5235e0b` test(audio) [carries all route-health prod files] · `d50eece`/`086bbc6`/
`3e9c327`/`3fd78f1` docs · `fd0d4b2` docs(research) · `e4cf7ce` feat(voice-filter).

## Next highest-leverage slice

`swiftui-implementer`: wire `RouteHealthMonitor` into `ContentView` /
`LiveTranscriptionViewModel`:
1. Inject monitor; render a route badge (`displayLabel`/`shortLabel`) with
   accessibility id `route-health-badge`.
2. Gate the Start button on `monitor.blocksStart` (disable + reason) — wire the
   already-correct `.noInput`-only logic.
3. On `.lost` while listening, **actually pause** `engine.stop()` and surface
   `bannerText` (`route-health-banner`) — make finding #2's copy true, or change
   the copy.
4. Add an XCUITest for start-gate + loss-banner.

Until that slice lands, do not market this as a user-visible route-health
feature.

---

## tester-unit deterministic Xcode evidence (2026-05-23)

Run: `dspeech-builder-20260523T190026Z-8ff9dfb0` · Role: `tester-unit` · Host: `ubuntu-vm` → mac24

### Commit under test

- Branch `feat/local-pilot-voice-filter` @ **`bdef438`** (origin == mac24 HEAD after `git pull --ff-only`).
- **Caveat — not a clean tree:** mac24 working tree carried uncommitted local
  modifications NOT in `bdef438`: `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift`
  (Swift-6 `@Sendable` tap/recognition refactor) and `DspeechUITests/DspeechUITests.swift`
  (added `testStartButtonDoesNotCrashAppWithPermissionsPreGranted`). These were left in
  place (in-flight work, not mine to discard). The unit run therefore reflects
  `bdef438` **plus those local mods**. The route-health unit targets are pure and
  independent of the ASR engine change, so the route-health verdict is unaffected; flagged for honesty.

### Static scope checks (vs `origin/main...HEAD`, route-health + capture files)

- Forbidden deps: **none** — `URLSession`/`Network.framework`/`NWPathMonitor`/`CoreML`/`.mlmodel`/`http(s)://`/telemetry/`dataTask` all absent. Route-health is pure `AVAudioSession` introspection behind the `AudioSessionRouting` protocol.
- Banned copy: **none** — no `certified`/`guaranteed`/`radio link`/`flight-safe`/`safety-critical` in `Dspeech/`.

### Commands run (deterministic shell on mac24)

```bash
ssh mac24 'cd /Users/andre/projects/dspeech-ios && git fetch origin feat/local-pilot-voice-filter \
  && git checkout feat/local-pilot-voice-filter && git pull --ff-only'   # → bdef438

# DEVELOPER_DIR required: default xcode-select points at CommandLineTools, not full Xcode.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Targeted first:
xcodebuild test -scheme Dspeech -destination "platform=iOS Simulator,name=iPhone 17" \
  -only-testing:DspeechTests/RouteHealthClassifierTests \
  -only-testing:DspeechTests/RouteHealthMonitorTests \
  -only-testing:DspeechTests/LiveTranscriptionViewModelTests

# Full unit suite:
xcodebuild test -scheme Dspeech -destination "platform=iOS Simulator,name=iPhone 17" \
  -only-testing:DspeechTests
```

Exact destination: `platform=iOS Simulator, name=iPhone 17, OS:26.4, arch:arm64, id:E072E456-F0C4-490A-800A-54EBB813237C` (iPhone 17 was installed; no fallback needed).

### Pass/fail

| Run | Result | Cases |
|-----|--------|-------|
| Targeted (classifier + monitor + view-model) | **TEST SUCCEEDED** | 59 passed, 0 failed |
| Full `DspeechTests` unit bundle | **TEST SUCCEEDED** | 105 passed, 0 failed |

Per-suite: RouteHealthClassifierTests 26 · RouteHealthMonitorTests 24 · LiveTranscriptionViewModelTests 9 · SpeakerMatcherTests 12 · CallSignTests 8 · VoiceFilterPipelineTests 7 · ATCTranscriptGateTests 7 · PrivacySettingsTests 6 · VoiceFilterStorageTests 3 · TranscriptSegmentTests 2.

Component-level start-gate logic is **green and correct**: `blocksStartOnlyForNoInput()` and `blocksStartWhenNoInput()` pass; copy guards `displayCopyAvoidsCertifiedLanguage()` / `bannerCopyAvoidsCertifiedLanguage()` pass.

### Limitations / not covered

- **UI/integration gap stands (confirms reviewer findings #1–#2).** `grep -rn RouteHealthMonitor Dspeech/` → 1 production definition, **0 production call sites**. No chip/banner in `ContentView`, no Start-button gate, no `.lost`→`engine.stop()` wiring. Unit tests exercise the monitor/classifier in isolation only; they cannot and do not prove the user-visible increment, because it is not wired. No view-model test covers route-health start-gating or external-loss→stop (nothing to test yet).
- `DspeechUITests` bundle **not run** — it drives the live mic/Start button and depends on simulator permission state; out of scope for a deterministic unit run, and the relevant route-health UI does not exist to assert against.

### Residual manual device smoke (after the wiring slice lands)

On a physical iPhone with an external ATC input source: (1) verify the route-health chip renders and updates on plug/unplug; (2) verify Start is disabled with a reason when no input is present; (3) verify that unplugging the external source mid-capture actually pauses ASR and surfaces the banner (today the copy claims «Запись приостановлена» but nothing pauses — must be true before that string ships).
