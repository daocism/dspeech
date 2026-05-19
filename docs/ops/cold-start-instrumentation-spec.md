# Cold-start instrumentation spec — signpost placement map

Status: draft — read-only placement map. This document does **not** add code; it
names every `os_signpost` anchor an implementation PR will drop into the boot
sequence so cold-start latency can be measured end-to-end against the budget.

Companion: `docs/ops/cold-start-latency-budget.md` — lives on sibling burn
branch `burn/13-cold-start-latency-budget` (not yet merged onto this branch).
Merge order is **budget first, then this spec**: the budget defines the per-gap
ceilings this spec's anchors will measure against; this spec names exactly
where the gaps begin and end.

## 1. Goal

Produce an `os_signpost`-based instrumentation surface dense enough to attribute
every millisecond from process launch to "first transcript frame visible", and
sparse enough that the instrumentation itself does not perturb the measurement.
The surface is the input to the cold-start latency budget; without it, the
budget can be written but not enforced.

Out of scope for the implementation PR that follows this spec: dashboards,
MetricKit integration, regression CI gating. Those land later (§9).

## 2. Measurement model

All measurements use a **monotonic** clock. No `Date.now`, no wall-clock
timestamps, no NTP-influenced sources — the device may sync time during the
boot window, which would silently corrupt deltas. The clock primitive is
`ContinuousClock.now` for high-level samples and the implicit clock embedded in
`os_signpost` interval IDs for gap measurement. Sleep-aware behavior is
intentionally accepted: if the OS suspends the process mid-boot (rare during a
cold start but possible under thermal throttle), the gap should widen and be
visible in the trace rather than be hidden by a monotonic-uptime fallback.

Anchor types:

- **point** — single `os_signpost` event, no `begin`/`end` pair. Used when the
  anchor marks a moment, not a span.
- **interval** — paired `begin`/`end` `os_signpost` calls sharing a single
  `OSSignpostID`. Used when the anchor measures the duration of a step inside
  the boot path (engine prepare, view-model construction).

Named timestamps:

- **t0** — `BOOT_T0`, emitted as the first statement of `DspeechApp.init`.
- **t1..tN** — every other anchor in §3, ordered by emission in a cold-start
  trace.
- **tF** — `FIRST_TRANSCRIPT_FRAME`, the point anchor that closes the
  end-to-end cold-start interval. Defined as: the first `body` evaluation of
  `ContentView` that produces a non-empty primary content region — either the
  empty-state copy when `liveViewModel.segments` and `partialText` are both
  empty, or the populated `ScrollView` branch when either has content.

Total cold-start latency = `tF − t0`. Per-gap latencies are derived from
adjacent anchors in §3.

## 3. Anchor inventory

Each row names: a stable UPPER_SNAKE_CASE anchor identifier, the file:line where
the emission call lands, the signpost phase, the kebab-case `name:` parameter
passed to `os_signpost`, and a short note on what the gap to the previous
anchor measures. Categories (§4) bind each anchor to an `OSLog` instance.

| Anchor | File:line | Phase | Signpost name | Notes |
| --- | --- | --- | --- | --- |
| `BOOT_T0` | `Dspeech/App/DspeechApp.swift:6` | point | `boot-t0` | First statement inside `DspeechApp.init`. Establishes t0; gap to previous = none. |
| `APP_INIT_RETURN` | `Dspeech/App/DspeechApp.swift:7` | point | `app-init-return` | Final line of `init` before SwiftUI begins evaluating `body`. Gap from `BOOT_T0` = work done in `init` (currently only `applyFirstRunLaunchOverride()` — a UserDefaults read). |
| `SCENE_PHASE_ACTIVE` | `Dspeech/App/DspeechApp.swift:10` | point | `scene-phase-active` | First `scenePhase == .active` transition observed from `.onChange(of: scenePhase)` attached to `WindowGroup`. The modifier does **not** exist yet; the implementation PR adds it on the `WindowGroup` block opened at line 10. Gap from `APP_INIT_RETURN` = SwiftUI scene construction + first phase emission. |
| `CONTENT_VIEW_INIT_BEGIN` | `Dspeech/App/ContentView.swift:17` | interval `begin` | `content-view-init` | Start of `ContentView.init`. Same `OSSignpostID` as `CONTENT_VIEW_INIT_END`. |
| `FIRST_RUN_GATE_DECISION` | `Dspeech/App/ContentView.swift:36` | point | `first-run-gate-decision` | Synchronous evaluation of `firstRunCoordinator.currentState()` that arms `_showFirstRun`. Gap from `CONTENT_VIEW_INIT_BEGIN` = the `UserDefaults` read in `UserDefaultsFirstRunStateStore.hasCompletedFirstRun`. |
| `CONTENT_VIEW_INIT_END` | `Dspeech/App/ContentView.swift:37` | interval `end` | `content-view-init` | Closes the `content-view-init` interval. |
| `LIVE_VM_INIT_BEGIN` | `Dspeech/App/LiveTranscriptionViewModel.swift:14` | interval `begin` | `live-vm-init` | Start of `LiveTranscriptionViewModel.init`. The default-injected engine constructor (`AppleSpeechLiveTranscriptionEngine()`) runs inside the surrounding `ContentView.makeDefaultLiveViewModel()` call site; the interval captures the VM's own stored-property assignment, not the engine constructor. |
| `LIVE_VM_INIT_END` | `Dspeech/App/LiveTranscriptionViewModel.swift:16` | interval `end` | `live-vm-init` | Closes `live-vm-init`. Currently a trivial body (single property assignment); the interval is retained to detect regressions if observation wiring grows. |
| `CONTENT_VIEW_FIRST_BODY` | `Dspeech/App/ContentView.swift:56` | point | `content-view-first-body` | First `body` getter invocation. A one-shot guard is required because SwiftUI may re-evaluate `body` many times per second — only the **first** call counts as t for this anchor. Implementation: a `nonisolated(unsafe) static var emitted: Bool` checked-and-set inside the getter. |
| `AUDIO_SESSION_PREPARE_BEGIN` | `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:76` | interval `begin` | `audio-session-prepare` | Start of `beginAudioSession()`. Note: this is the **ASR-owned** audio session activation that runs on first tap of the Start button, **not** any of the AudioInputService activations (`Dspeech/Core/Audio/AudioInputService.swift:110`, `:124`, `:135`) which are triggered by the Settings audio-source picker, not by cold start. |
| `AUDIO_SESSION_PREPARE_END` | `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:80` | interval `end` | `audio-session-prepare` | Closes `audio-session-prepare`. |
| `AUDIO_ENGINE_START` | `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:102` | point | `audio-engine-start` | Emitted immediately after `try audioEngine.start()` returns. Gap from `AUDIO_SESSION_PREPARE_END` = `AVAudioEngine.prepare()` + `start()`. |
| `FIRST_PCM_BUFFER` | `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:95` | point | `first-pcm-buffer` | First non-empty `AVAudioPCMBuffer` arriving at the `installTap` block. One-shot guard required: a tap fires continuously while the engine runs. The guard lives on the engine instance (`var didEmitFirstBuffer: Bool`) and is reset by `cleanup()` so a subsequent listening session can re-emit it (useful but not part of cold-start aggregation). |
| `RECOGNIZER_FIRST_RESULT` | `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:107` | point | `recognizer-first-result` | First non-nil `result` inside the `recognitionTask` completion handler. One-shot guard mirrors `FIRST_PCM_BUFFER`. |
| `TRANSLATION_SESSION_FIRST_INIT` | `Dspeech/Core/Translation/TranslationService.swift:97` | point | `translation-session-first-init` | First construction of `TranslationSession(installedSource:target:)`. Lazy: only emitted when the user has translation enabled and a recognized segment reaches `AppleTranslationService.translate(_:from:into:)`. May never fire during a pure "open and read transcripts" cold start. The anchor is in the inventory so it is **available** to attribute translation latency on the first translated segment, not as a mandatory step in the boot path. |
| `FIRST_TRANSCRIPT_FRAME` | `Dspeech/App/ContentView.swift:134` | point | `first-transcript-frame` | tF. Closes the end-to-end cold-start window. One-shot guard required (SwiftUI re-evaluates `body` repeatedly). Implementation: a flag flipped on the first evaluation where the `else` branch of `transcriptArea` (segments non-empty or partial non-empty) is taken, **or** where the empty-state branch first reports a stable layout. The implementation PR will pick one definition (preference: non-empty branch, because that is what the user perceives as "the app is ready"); §10 records this as Open Question Q1. |

Anchor count: 16. Required minimum from the task definition (`BOOT_T0`,
`SCENE_*`, `CONTENT_VIEW_FIRST_BODY`, `LIVE_VM_INIT_BEGIN/END`,
`AUDIO_SESSION_PREPARE_BEGIN/END`, `FIRST_PCM_BUFFER`, `RECOGNIZER_FIRST_RESULT`,
`FIRST_TRANSCRIPT_FRAME`) is satisfied with margin.

## 4. Subsystem signposts (`OSLog` categories)

All emissions go through a single per-category `Logger`-adjacent `OSLog`
instance (the `os_signpost` API requires `OSLog`, not `Logger` — `Logger` is the
unified-logging text surface, `OSLog` is the signpost surface; they share a
subsystem string and complement each other).

Subsystem (reverse-DNS, single literal): `com.dspeech.cold-start`.

Categories — one `OSLog` constant per category, declared `static let` on a
zero-dependency `enum BootSignpost` namespace the implementation PR will create
in `Dspeech/Core/Ops/`:

| Category | Anchors |
| --- | --- |
| `boot` | `BOOT_T0`, `APP_INIT_RETURN`, `SCENE_PHASE_ACTIVE`, `CONTENT_VIEW_INIT_BEGIN`, `CONTENT_VIEW_INIT_END`, `CONTENT_VIEW_FIRST_BODY` |
| `firstrun` | `FIRST_RUN_GATE_DECISION` |
| `audio` | `AUDIO_SESSION_PREPARE_BEGIN`, `AUDIO_SESSION_PREPARE_END`, `AUDIO_ENGINE_START`, `FIRST_PCM_BUFFER` |
| `asr` | `LIVE_VM_INIT_BEGIN`, `LIVE_VM_INIT_END`, `RECOGNIZER_FIRST_RESULT` |
| `translation` | `TRANSLATION_SESSION_FIRST_INIT` |
| `ui` | `FIRST_TRANSCRIPT_FRAME` |

Filtering in Instruments / `log stream` is then a single
`subsystem == "com.dspeech.cold-start"` predicate, optionally narrowed by
category.

## 5. Sampling protocol

Per-trial procedure (operator-driven, on a real device — Simulator timing is
not representative of cold-start cost):

1. Force-quit the app from the multitasking switcher.
2. Wait 60 s with the screen on. This drains the warm-start path that iOS keeps
   for recently-killed processes.
3. Lock the device, unlock, immediately tap the Dspeech icon.
4. Tap Start as soon as the surface is interactive. Stop after the first
   recognized segment renders.
5. Export the Instruments `os_signpost` trace for that run.

Run count: at least 10 trials per environment configuration. Report all 10 as
the raw input to aggregation (§6); do not discard outliers before aggregation —
p99 is one of the budget anchors.

Environment requirements (each trial):

- Battery > 50 %. Below 50 %, iOS may already be in a low-power influence zone
  even without Low Power Mode toggled.
- Low Power Mode: off.
- Thermal state at trial start: `nominal` (verified via `ProcessInfo`).
- Brightness fixed (manual, not auto). Recommended: 50 %.
- Network: airplane mode on. Cold-start must not depend on or be perturbed by
  network state — the app is local-only by default (ADR 0002), so disabling
  network also enforces that no accidental egress on this path exists.
- Audio route: built-in mic. Hardware path (wired headset / USB) cold-start
  characterization is a separate workstream.

Reference for the `os_signpost`-based cold-start measurement approach in
Instruments / MetricKit: UNKNOWN — verify before adoption. The implementation PR
must cite the exact Apple Developer URL (DocC slug) for the
`MXAppLaunchMetric` integration claim before it is relied on; a stub link is
not acceptable.

## 6. Aggregation

For each anchor-pair gap (e.g. `BOOT_T0` → `APP_INIT_RETURN`,
`AUDIO_SESSION_PREPARE_BEGIN` → `AUDIO_SESSION_PREPARE_END`, end-to-end
`BOOT_T0` → `FIRST_TRANSCRIPT_FRAME`), report:

- p50, p90, p99 across the trial set.
- the worst-case run preserved verbatim as a representative trace (saved as a
  `.trace` bundle alongside the aggregated CSV, so the long-tail run can be
  re-opened in Instruments without re-collecting).

Aggregation script: `Scripts/cold-start-aggregate.sh` — a future artifact, not
part of this spec. The script will consume the exported trace CSV format
Instruments produces from `os_signpost` events.

## 7. Anti-perturbation rules

The instrumentation must not move the measurement it captures. Implementation
PR rules:

- Signpost `name:` strings must be **static literal** kebab-case strings (e.g.
  `"first-pcm-buffer"`). No String interpolation in the `name:` slot — `OSLog`
  formats and interns names; runtime-built strings break that path and add
  allocation cost.
- All category `OSLog` instances are `static let` on `BootSignpost`. No
  per-anchor `OSLog(subsystem:category:)` construction; that would re-allocate
  each emission.
- No file I/O, no UserDefaults writes, no Keychain reads, no network on the
  boot path triggered **solely** by instrumentation. The existing
  `applyFirstRunLaunchOverride()` UserDefaults read is pre-existing and is
  measured **by** instrumentation, not introduced by it.
- No `print()`, no `dump()`, no `NSLog()` on the boot path. They buffer through
  stdio and skew measurements unpredictably under load. `os_signpost` is the
  only allowed emission primitive on the boot path.
- Tap-block emission (`FIRST_PCM_BUFFER`) must be guarded by a single
  atomic-read of a `Bool` flag to avoid emitting on every buffer; the guard
  cost must itself be ≤ a single load + compare-and-set.
- One-shot guards for `CONTENT_VIEW_FIRST_BODY`, `FIRST_PCM_BUFFER`,
  `RECOGNIZER_FIRST_RESULT`, `FIRST_TRANSCRIPT_FRAME` must reset on
  `LiveTranscriptionEngine.cleanup()` so a subsequent listening session inside
  the same process can re-emit the audio-side anchors for warm-start
  characterization (separate workstream, but the reset costs nothing to
  reserve now).

## 8. Validation strategy

A PR that lands the instrumentation is accepted only after:

1. **Anchor cross-check by grep.** For every row in §3, `grep -n` for the
   signpost `name:` literal in the file at the cited line ±5 finds exactly one
   match. The check runs as a one-line `grep` invocation per row; failures
   block merge.
2. **Anchor count test.** A new XCTest case launches the app with a deterministic
   first-run state, drives the Start button, waits for a first segment, then
   reads the recent `os_signpost` events from the `OSLog` store and asserts the
   set of emitted names. Approach: RESEARCH NEEDED — the canonical Apple path
   for ingesting `os_signpost` events from XCTest is via Instruments rather than
   in-process inspection, and the in-process surface (`OSLogStore`) is
   intentionally read-only and rate-limited. The implementation PR must either
   cite a working approach or replace this gate with a manual-trace gate.
3. **Manual Instruments trace inspection.** One full trace is captured and
   attached to the implementation PR; reviewers verify visually that every
   anchor in §3 appears in the expected order and that the end-to-end window
   falls within the budget.
4. **Cold-start budget cross-reference.** The implementation PR must reference
   `docs/ops/cold-start-latency-budget.md` (once merged) and demonstrate that
   the median trace falls inside the budget. The budget must already be on the
   branch — this spec assumes that ordering (§1).

## 9. Future work (explicitly deferred)

Each item names its eventual home, so this spec stays narrowly scoped:

- **MetricKit `MXAppLaunchMetric` integration** — its own future task. The
  app-launch histogram MetricKit reports complements but does not replace the
  per-anchor `os_signpost` surface this spec defines (MetricKit attributes
  end-to-end launch time only; the gap breakdown requires our own anchors).
- **Signpost-driven dashboards** (CI artifact, Grafana, or Asciidoc table in
  `docs/ops/`) — its own future task. Producing the CSV is a prerequisite; the
  presentation layer is not.
- **Pre-warming `TranslationSession`** to shorten p99 of the
  `TRANSLATION_SESSION_FIRST_INIT` anchor — a product decision, not an
  instrumentation decision. Defer until at least one round of measurement has
  shown whether pre-warming is necessary.
- **Warm-start characterization** — same anchors, different sampling protocol
  (no force-quit + idle). The §3 inventory is already warm-start-safe because
  one-shot guards are reset by `cleanup()`; a separate spec will define the
  warm-start sampling protocol.
- **Regression CI gate** — block merge if median end-to-end widens by more than
  a budget-defined fraction. Requires the aggregation script (§6) and a baseline
  artifact committed to the repo.

## 10. Open questions (falsifiable)

Each names the artifact that resolves it.

- **Q1.** Does `FIRST_TRANSCRIPT_FRAME` count the empty-state branch as t-final,
  or only the populated-transcript branch? Resolved by: the implementation PR
  picks one definition and documents it in the signpost site comment; the
  budget doc is updated to match. Preference: populated branch — that is what
  the user perceives as "ready".
- **Q2.** Is `OSLogStore`-based in-process anchor-count assertion viable under
  XCTest on a real device (§8.2), or must the validation gate be a manual
  Instruments trace? Resolved by: a 10-line spike that attempts to read
  `OSLogStore` entries for our subsystem from inside an XCTest case and
  either succeeds or fails with a documented reason.
- **Q3.** Does `os_signpost` emission inside the realtime `AVAudioEngine` tap
  block (`FIRST_PCM_BUFFER`) introduce audible glitches or buffer underruns at
  the configured 1024-frame buffer size? Resolved by: an A/B trace with and
  without the emission, comparing tap-block duration via existing buffer
  metering. If the cost is non-negligible, the anchor moves to the first
  partial-result emission instead (point anchor `first-partial-result`).
- **Q4.** Should `SCENE_PHASE_ACTIVE` be implemented via `.onChange(of:
  scenePhase)` on `WindowGroup` (declarative) or via a `UIWindowScene`
  delegate-style observer (imperative)? Resolved by: the implementation PR
  picks one and documents trade-offs (declarative is simpler but the `.active`
  callback timing has historically lagged `applicationDidBecomeActive` by a
  frame; imperative is more precise but introduces `UIKit` import into the
  pure-SwiftUI app). The spec is approach-agnostic.

## 11. References

- ADR 0001 — iOS-first, local-first (`docs/adr/0001-ios-first-local-first.md`).
- ADR 0002 — privacy: local-only default
  (`docs/adr/0002-privacy-local-only-default.md`). Relevant to §5: airplane
  mode during measurement also enforces the no-egress invariant.
- Cold-start latency budget — `docs/ops/cold-start-latency-budget.md` on
  sibling branch `burn/13-cold-start-latency-budget`. Not yet on this branch;
  merge order: budget first, then this spec.
- Source files cited in §3 (every anchor's file:line is one of these):
  - `Dspeech/App/DspeechApp.swift`
  - `Dspeech/App/ContentView.swift`
  - `Dspeech/App/LiveTranscriptionViewModel.swift`
  - `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift`
  - `Dspeech/Core/Translation/TranslationService.swift`
- AudioInputService activation sites referenced for **contrast** (not cold-start
  path): `Dspeech/Core/Audio/AudioInputService.swift:110`, `:124`, `:135`.
