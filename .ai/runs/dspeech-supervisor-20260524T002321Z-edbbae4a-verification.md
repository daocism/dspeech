# Route-health UX — independent verification (2026-05-24)

Run: `dspeech-supervisor-20260524T002321Z-edbbae4a`
Role: `tester-unit`
Host: `ubuntu-vm` (static checks + git) / `mac24` (deterministic Xcode run)

## Verdict: VERIFIED — route-health UX is wired, deterministic Xcode `build test` + Release build both PASS

The prior AI Office finalizer's `BLOCKED: implementation artifact missing` label is **stale**.
At that finalizer's write time (run `20260523T132443Z-1c576edf`, ~15:34–15:35) the Swift
UX files were still uncommitted, so its verdict reflected an empty working tree. They have
since landed in commit `b671f74`, and this run verifies them from a clean mac24 clone.

## Branch & SHA under test

- Branch: `feat/local-pilot-voice-filter`
- Local + `origin/...` HEAD: `b671f74 feat(audio): surface route health in capture UI`
- `git status --short --branch`: clean, in sync with remote.
- mac24 clean-clone `git rev-parse --short HEAD`: `b671f74` (matches).

## Commands & outputs (summarized)

| Command | Result |
|---|---|
| `git status --short --branch` | clean; `...origin/feat/local-pilot-voice-filter` |
| `git log --oneline -12` | HEAD `b671f74`; UX commit on top of route-health model/test history |
| `git diff --stat origin/main...HEAD -- <paths>` | 24 files, +2970 / −13; UX files all present |
| mac24 clean clone (`git clone --branch feat/local-pilot-voice-filter`) | `CLONED_HEAD=b671f74` |
| `xcodebuild -scheme Dspeech -destination "iPhone 17,OS=26.4" -quiet build test` | **`BUILD_TEST_EXIT=0`** — all test cases passed, "Testing started completed" 54.3s, zero failures |
| `xcodebuild -scheme Dspeech -configuration Release ... -quiet build` | **`RELEASE_BUILD_EXIT=0`** |

Test suites observed green on simulator (iPhone 17 / iOS 26.4): `RouteHealthMonitorTests`,
`RouteHealthClassifierTests`, `CaptureCoordinatorTests`, `LiveTranscriptionViewModelTests`,
`VoiceFilterPipelineTests` / `VoiceFilterTests`, `CallSignTests`, `PrivacySettingsTests`.

### mac24 shell note (not a product defect)

First clean-run attempt aborted at exit code 1 *after* all tests passed, because mac24's
default shell is **zsh**, where the task's literal `${PIPESTATUS[0]}` under `set -u` raises
`PIPESTATUS: parameter not set`. Re-ran with a portable `rc=$?` capture (build/test commands
unchanged) → both phases exit 0. The first run's test output already showed every case passing;
the second run confirms deterministically with both exit codes captured.

## Route-health UX wiring — CONFIRMED

- **`ContentView` constructs/uses `CaptureCoordinator`** — `@State private var coordinator`
  initialized in `init` (`ContentView.swift:4,19`); all start/stop routed through `coordinator`.
- **Visible route-health surface with stable a11y id** — `RouteHealthChip`
  (`ContentView.swift:257`) renders health-driven icon/tint + monospaced short label, carries
  `accessibilityIdentifier("route-health-chip")` and an `accessibilityLabel`. Advisory banner
  carries `accessibilityIdentifier("route-banner")`.
- **Start gated on `RouteHealthMonitor.blocksStart`** — `coordinator.canStart == !blocksStart`;
  `start()` early-returns and sets `startBlockedMessage` when blocked; start button disabled via
  `startDisabled = !isListening && !canStart` (`ContentView.swift:137`). `blocksStart` is true
  only for `.noInput`.
- **`.lost` external→built-in stops capture through the coordinator** — `RouteHealthMonitor`
  emits `.lost` only on `oldDeviceUnavailable` transitioning `.suitableExternal → non-external`
  (`RouteHealthMonitor.swift:82-89`); `CaptureCoordinator.handleRouteEvent` calls `live.stop()`
  when `lastNotice.kind == .lost && live.isListening` (`CaptureCoordinator.swift:57-62`).
  Covered by `CaptureCoordinatorTests/oldDeviceUnavailableExternalToBuiltInStopsAndShowsNotice`
  (stop called, `.lost` notice user-visible) and the idle-path negative test
  `oldDeviceUnavailableWhenIdleDoesNotCallStop` — both green on mac24.

## Privacy / safety guardrails — CONFIRMED

- **No new network/upload code** — grep for `URLSession|URLRequest|dataTask|upload|http(s)://|
  NWConnection|socket|websocket` across `Dspeech/App` + `Dspeech/Core/Audio` + `Dspeech/Core/VoiceFilter`
  returns nothing. Route-health is pure `AVAudioSession` introspection behind the
  `AudioSessionRouting` protocol.
- **No forbidden marketing claims** in production source — `certified|guaranteed|flight-safe|
  radio link|tower link|FAA|EASA` appear ONLY inside test guard assertions
  (`CaptureCoordinatorTests` `forbiddenSubstrings`, `RouteHealthMonitorTests`
  `displayCopyAvoidsCertifiedLanguage` / `bannerCopyAvoidsCertifiedLanguage`) and the run-note
  doc — zero in shipped strings. These guards run green on mac24.
- **Source audio/replay stays canonical** — route-health does not couple into
  `LiveTranscriptionViewModel`'s transcript/audio source path; it lives in `CaptureCoordinator`
  as advisory/gating metadata only. The only VM diff line touching these terms is a Phase-2
  voicefilter comment, unrelated to route health.

## Stale-status mismatch found

- Prior finalizer `20260523T132443Z-1c576edf-final.md`: verdict
  `BLOCKED: implementation artifact missing` — stale; written before `b671f74` committed the UX.
- Reviewer handoff `docs/run-notes/2026-05-23-route-health-ux.md`: REQUEST_CHANGES findings
  **#1 (no route-health surface / start never gated)** and the checklist item
  **"Loss of external input while listening does not silently continue — FAILS"** are both now
  **resolved** by `b671f74` (coordinator wired, start gated, `.lost` stops capture). That doc's
  pre-`b671f74` framing is stale; see this note for current state. Reviewer finding #2 (`.lost`
  banner over-claimed "приостановлена" before wiring existed) is no longer a lie now that the
  coordinator actually stops capture on `.lost`.

## Residual product risk / manual smoke still needed

- **Real-device route smoke** — all `.lost` / `blocksStart` evidence is from injected
  `FakeAudioSessionRouting`; a physical USB/Bluetooth-mic disconnect on a real iPhone has not
  been exercised. Recommend a manual device smoke: enroll external mic → start → unplug →
  confirm capture stops and `route-banner` appears.
- **AirPlay-as-capture** (reviewer finding #3, MEDIUM) — `.airPlay → .suitableExternal` is
  intentionally pinned; product confirmation still open for ATC audio.
- **Commit hygiene** (reviewer finding #4) — historical: route-health production files first
  landed under a `test(` commit. Cosmetic now that `b671f74` exists; no action required for shippability.
