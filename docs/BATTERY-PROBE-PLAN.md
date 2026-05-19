# Battery probe plan — F7 verification

Date: 2026-05-19. Status: draft. Owner of execution: Andrei (device-only gate per `docs/PLAN-2026-05-19.md`).

## What we are proving

PRD `F7`: continuous live ASR session drains ≤ **25 % of battery per 60 minutes** on the iPhone 15 baseline (target also applied to iPhone 17 Pro Max — Andrei's reference device). See `docs/product/prd-ios-mvp.md:56` and `docs/eval/asr-benchmark-plan.md:35`.

Design-only document. No code lands as part of this plan; instrumentation hooks (`MetricKit` subscriber) ship under a separate ticket if §6 triage requires them.

## 1. Device pre-conditions (every run, no exceptions)

| Item | Setting | Why |
|---|---|---|
| Battery level | **100 %**, unplugged ≥ 5 min before start | Settings → Battery reports per-hour bucket only at full top-off; cable thermal drift affects ANE clock. |
| iOS build | iOS 26 release (no betas mid-run) | MetricKit payload format pinned. |
| Airplane mode | **ON** | Translation is fully on-device (ADR 0002), ASR is on-device. Radio idle drain is pure noise; eliminate it. Wi-Fi + Bluetooth toggled off explicitly even with airplane on. |
| Location services | OFF for Dspeech | Removes GPS as a drain confounder. |
| Display brightness | 50 % (slider centre), auto-brightness OFF, True Tone OFF, Night Shift OFF | Display is the #1 confounder. Same %, same panel state, every run. |
| Auto-lock | **Never** | Screen stays on for the full 60 min; matches the cockpit-use posture. |
| Low Power Mode | OFF | LPM throttles the ANE; would mask a real F7 regression. |
| Background App Refresh | OFF (system-wide) | Eliminates noise from other apps. |
| Other apps | Force-quit before each run | Same. |
| Temperature | Room, 20–24 °C; device on a non-insulating surface | Thermal throttling skews repeatability. |
| Charge cycles on battery | < 200 (note in `hardware.json`) | Older cells distort %/h. |
| Privacy mode in Dspeech | `LOCAL` badge visible (CLAUDE.md hard rule 4) | Confirms no cloud egress could occur. |

Record device serial, iOS build, battery Maximum Capacity %, and starting battery % in the run log (artifact layout below).

## 2. Measurement instruments (two independent sources, agree-or-investigate)

1. **Settings → Battery (Last 24 Hours, per-app)** — primary user-facing number. Screenshot at start, +30 min, +60 min. The per-app row for "Dspeech" gives "Screen On" and "Background" minutes plus a percentage that maps to the F7 bar.
2. **Console.app on mac24 paired over USB / Wi-Fi**, subsystem filter `com.apple.metrickit` and `com.dspeech.app` — captures the `MXMetricPayload` Apple sends ~once per 24 h, plus our own subscriber if installed (see §5). Relevant fields: `MXCPUMetric.cumulativeCPUTime`, `MXCPUMetric.cumulativeCPUInstructions`, `MXDiskIOMetric.cumulativeLogicalWrites`, `MXAppRunTimeMetric.cumulativeForegroundTime`, `MXMemoryMetric.peakMemoryUsage`.
3. **Settings → Battery → Battery Health & Charging** screenshot at start to record Maximum Capacity %.

Secondary cross-checks (informational, not pass/fail):
- Xcode → Window → Devices and Simulators → Battery shows live SoC % at 1-min granularity when the device is tethered, **but** tethering charges the device. Use only for un-tethered live read via the `idevicebattery` flow if available, otherwise rely on the device's own Settings UI screenshots.

## 3. Scenarios (three runs, in this order, on a single 100 % charge across separate days — do **not** stack on one charge)

Each run is 60 min, screen on, started from 100 %, with the pre-conditions in §1.

### S1 — Idle baseline
- Dspeech foregrounded on the live transcript view.
- Microphone **not** started (no `AudioCaptureService.start`).
- Translation toggle OFF.
- Purpose: isolates display + SwiftUI render + system idle drain. Establishes the floor below which scenarios S2/S3 cannot go.

### S2 — Live ASR, no translation
- Dspeech foregrounded.
- Built-in mic, audio source picker on default. Privacy mode LOCAL.
- "Start listening" pressed at t = 0; speech fed continuously (loop a 60-min sample of `synth_pilots` over external Bluetooth speaker placed ~30 cm from the iPhone, OR use a held headset talker — same source for every run, recorded in `hardware.json`).
- Translation toggle OFF.
- Purpose: the actual F7 number. ASR + display + capture + render.

### S3 — Live ASR + translation
- Identical to S2 plus: translation toggle **ON** with one language pair already downloaded (en → ru). Verify "downloaded" before t = 0.
- Purpose: incremental cost of the Apple Translation pipeline running on every finalized segment.

Per-run output goes under:

```
eval/runs/battery_<device>_<scenario>_<YYYY-MM-DD>/
  hardware.json            # device, iOS build, battery max capacity %, ambient temp, audio source
  settings_start.png       # Settings → Battery + Battery Health screenshot at t=0
  settings_30m.png         # at +30 min
  settings_60m.png         # at +60 min
  metrickit_payload.json   # decoded MXMetricPayload if available
  console_log.txt          # filtered Console.app capture
  notes.md                 # anything anomalous (thermal warning, audio dropout, beachball)
```

## 4. Pass criteria

| Scenario | Pass | Investigate | Fail |
|---|---|---|---|
| S1 idle | ≤ 8 %/h | 8–12 %/h | > 12 %/h |
| S2 live ASR | ≤ 25 %/h | 25–30 %/h | > 30 %/h |
| S3 ASR + translation | ≤ 30 %/h (S2 + ≤ 5 pp) | 30–35 %/h | > 35 %/h or > S2 + 8 pp |

Two independent runs of the failing scenario before declaring fail (battery telemetry has ~2 pp noise floor).

Pass = F7 closed. Investigate = §6 triage. Fail = F7 open, block 1.0 ship per ADR 0006.

## 5. Instrumentation hooks (only added if §6 triage requires them)

`MetricKit` subscriber is **not currently in the codebase** (`grep MetricKit` returns zero hits at the time of writing). If the §6 triage points at CPU or disk-IO regression, add it:

- File: `Dspeech/Core/Diagnostics/MetricsSubscriber.swift` (new), behind a `Diagnostics` SwiftUI scene-modifier registered at `DspeechApp` boot.
- Conforms to `MXMetricManagerSubscriber`, persists payloads to `Documents/metrics/<iso8601>.json` for off-device pull via Finder file sharing.
- Gated by `#if DEBUG || DSPEECH_PROBE` — does not ship in App Store builds (ADR 0002 / CLAUDE.md "no covert background capture"). Privacy mode badge unaffected.
- Tests: a single Swift Testing case that round-trips a synthetic `MXMetricPayload`-shaped fixture through the persistence path.

Until then, rely on the Apple-emitted `MXMetricPayload` (one per 24 h) that Console.app surfaces, plus the Settings → Battery screenshots in §2.

## 6. Failure triage tree

If S1 fails (idle too hot):
1. Check Settings → Battery → "Screen On" matches wall-clock 60 min. If not, auto-lock was on — invalidate run.
2. Confirm airplane mode actually engaged (status bar). Wi-Fi/BT sometimes re-enable themselves on iOS 26 after a settings sync — toggle off explicitly.
3. Suspect Dspeech main-thread render churn: profile in Instruments → SwiftUI → "View body count" for the live transcript view. Anything > a few Hz on an idle screen is a regression.

If S2 fails (live ASR too hot) but S1 passed:
1. Open Instruments → Energy Log + CPU profiler on a tethered repro of S2.
2. Inspect the ASR adapter chosen by the build (`SpeechRecognitionService`): WhisperKit `large-v3-turbo` is the suspected ceiling; `small.en` or Apple SpeechAnalyzer should be the F7-safe fallback per `docs/eval/asr-benchmark-plan.md`.
3. Check audio capture buffer size — under-sized buffers cause excess wakeups; over-sized buffers stall the ANE pipeline.
4. Verify no debug logging at info-or-above inside the audio thread (string interpolation on a 50 Hz callback burns CPU).
5. Add the §5 subscriber, re-run S2, read `MXCPUMetric.cumulativeCPUInstructions` — compare against an `synth_pilots` baseline captured on the green build.

If S3 fails but S2 passed:
1. Confirm the translation language pack is local (`Settings → General → Translation Languages` shows "Downloaded"). If translation silently falls back to a network path, that's an ADR 0002 violation, not an F7 issue — escalate immediately.
2. Inspect `TranslationService` invocation cadence — translation must fire once per finalized segment, not on every interim hypothesis. If per-interim, that's the regression.
3. If per-segment and still over budget, the pack itself is heavier than budgeted; record and route to architect for ADR 0007 amendment.

If all three pass: F7 closes, attach the run artifacts to the handoff entry under `docs/handoff.md`.

## 7. Out of scope

- Cellular-on / Wi-Fi-on variants (additive drain, not part of the F7 contract).
- Multi-hour endurance (covered by F6 crash-free, separate probe).
- Comparative engine bake-off (covered by `docs/eval/asr-benchmark-plan.md`).
- Cloud paths (forbidden by ADR 0002).
