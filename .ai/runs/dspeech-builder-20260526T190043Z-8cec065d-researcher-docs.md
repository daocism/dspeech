# researcher-docs — VAD / silence-gap utterance segmentation source pack

- Run: `dspeech-builder-20260526T190043Z-8cec065d`
- Role: researcher-docs
- Branch: `feat/local-pilot-voice-filter`
- Date: 2026-05-26
- Scope: source verification + smallest-slice recommendation. **No source code edited.**

## TL;DR for implementer/tester

Replace the fixed `decisionWindowSeconds = 1.0` cut in `UtteranceWindowRouter` with a
**pure-Swift, injected `SpeechActivitySegmenter` seam** whose default implementation is a
deterministic RMS-energy silence-gap detector. The router cuts a decision window when the
segmenter reports *enough trailing silence after speech* OR a *conservative max-window cap*
is reached. Sub-threshold / no-speech / uncertain tails still fail open to ASR.

**Do not wire FluidAudio's Silero VAD into production in this cycle.** It exists and is real
(see below), but it requires a third CoreML model asset that the current installed pack does
**not** ship, and the only download path is HuggingFace — both of which collide with the
local-only contract (CLAUDE.md hard rule #1) and ADR 0008's installed-only pack contract.
Leave a documented adapter point for a future `FluidAudioVADSegmenter` backend.

---

## 1. Apple APIs (the slice does not change how these are called)

The slice changes *when* the router cuts a window; it does not change Apple Speech / AVFAudio
usage. The relevant symbols are already in use and **compile against the iOS 26.4 SDK on mac24
with `DspeechTests` green** at branch tip `c0ea850` — that compiling usage is the verification,
since Apple's JS-rendered doc pages could not be retrieved from this run environment via WebFetch
or Context7 (both returned a permission/empty-render error). Canonical doc URLs are cited as the
authoritative upstream reference.

### `SFSpeechAudioBufferRecognitionRequest`
- Doc: <https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest>
- Verified in-repo usage (`AppleSpeechLiveTranscriptionEngine.swift`):
  - `func append(_ audioPCMBuffer: AVAudioPCMBuffer)` — line 116, `self?.request?.append(buffer)`.
  - `func endAudio()` — line 254, `request?.endAudio()`.
  - `var shouldReportPartialResults: Bool` — line 92.
  - `var requiresOnDeviceRecognition: Bool` — line 93 (set `true`; on-device only, supports rule #1).
  - `var addsPunctuation: Bool` — line 96, gated `if #available(iOS 16.0, *)`.
  - `var taskHint: SFSpeechRecognitionTaskHint` — line 94 (`.dictation`).
- Availability: class is iOS 10.0+; `addsPunctuation` iOS 16.0+; `requiresOnDeviceRecognition` iOS 13.0+.
- Deprecation: none affecting the symbols above on the iOS 26 SDK. (Apple is previewing a newer
  `SpeechAnalyzer`/`SpeechTranscriber` async API in the Speech framework; it is **not** required
  for this slice and is out of scope — do not migrate here.)
- **Slice implication:** the contract that buffers are appended/endAudio'd stays identical. The
  segmenter only decides grouping boundaries upstream of `append`.

### `AVAudioNode.installTap(onBus:bufferSize:format:block:)`
- Doc: <https://developer.apple.com/documentation/avfaudio/avaudionode/installtap(onbus:buffersize:format:block:)>
- Verified in-repo usage (`AppleSpeechLiveTranscriptionEngine.swift:123`):
  ```swift
  inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in ... }
  ```
- Signature: `func installTap(onBus bus: AVAudioNodeBus, bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block tapBlock: @escaping AVAudioNodeTapBlock)` where `AVAudioNodeTapBlock = (AVAudioPCMBuffer, AVAudioTime) -> Void`.
- Availability: iOS 8.0+. Gotcha (already handled in repo): `bufferSize` is a *request*; the
  hardware may deliver a different frame count per callback, so never assume `1024`. The
  segmenter must operate on actual `frameLength`, not the requested size.

### `AVAudioPCMBuffer.frameLength`
- Doc: <https://developer.apple.com/documentation/avfaudio/avaudiopcmbuffer/framelength>
- Verified in-repo usage (`AppleSpeechLiveTranscriptionEngine.swift:201`): `let frameLength = Int(buffer.frameLength)`.
- Signature: `var frameLength: AVAudioFrameCount` (`AVAudioFrameCount` = `UInt32`). `<= frameCapacity`.
  Duration of a buffer = `frameLength / format.sampleRate` seconds.
- Availability: iOS 8.0+.
- **Slice implication:** silence-gap math must accumulate real `frameLength` per buffer to track
  elapsed speech/silence seconds; the repo already converts to mono `[Float]` via
  `monoFloatSamples(from:)` (line 196) which is exactly the input a pure segmenter needs.

---

## 2. FluidAudio VAD — real, but NOT wireable this cycle

- Package resolved: **FluidAudio `0.14.7`** (`Package.resolved` rev `8048812869b0c7c6fa393e564a4fb6f95126ba23`),
  pinned `upToNextMajorVersion` from `0.14.7` in `Dspeech.xcodeproj/project.pbxproj:177`.
- Source: <https://github.com/FluidInference/FluidAudio> (Swift 6.0+, MIT/Apache-2.0 models).
- VAD doc (tag v0.14.7): `Documentation/VAD/GettingStarted.md`
  <https://raw.githubusercontent.com/FluidInference/FluidAudio/v0.14.7/Documentation/VAD/GettingStarted.md>

### Confirmed public VAD symbols (exact, from v0.14.7 docs)
- `actor VadManager`
  - `init(config: VadConfig = .default) async throws` — default path downloads the model from HuggingFace.
  - `init(config: VadConfig, vadModel: MLModel)` — manual/offline staging, **no network**.
  - `static let sampleRate` — 16 kHz operating rate.
  - `func process(_ samples: [Float]) async throws -> [VadResult]` — per-256 ms-hop probabilities.
  - `func segmentSpeech(_ samples: [Float], config: VadSegmentationConfig) async throws -> [<segment with startTime/endTime>]`
  - `func segmentSpeechAudio(_ samples: [Float], config: VadSegmentationConfig) async throws -> [<buffered clip>]`
  - `func makeStreamState() async -> VadStreamState`
  - `func processStreamingChunk(_ chunk: [Float], state: VadStreamState, config: VadConfig = .default, returnSeconds: Bool, timeResolution: Int) async throws -> VadStreamResult`
- `struct VadConfig` — `init(defaultThreshold:)`, `.default`.
- `struct VadSegmentationConfig` — `.default`; knobs: `minSpeechDuration`, `minSilenceDuration`,
  `maxSpeechDuration` (default 14 s), `speechPadding`, `negativeThreshold`/`negativeThresholdOffset`
  (Silero-style hysteresis).
- `struct VadResult` — `probability: Float`, `processingTime` (per 4096-sample chunk).
- `VadStreamState`, `struct VadStreamResult` — `.state`, `.event`, `.probability`.
- `VadStreamEvent` — `.kind` ∈ `{ .speechStart, .speechEnd }`, `.time: Double?`.

The streaming API (`makeStreamState` + `processStreamingChunk` emitting `.speechStart`/`.speechEnd`)
is exactly the shape a future utterance-edge segmenter would consume.

### Why it is blocked for this cycle (the decisive constraints)
1. **Different model asset, not in the pack.** VAD needs
   `silero-vad-unified-256ms-v6.0.0.mlmodelc` from repo **`FluidInference/silero-vad-coreml`**.
   The installed pack (`SpeakerModelPackInstaller.swift:11-16`, source
   `FluidInference/speaker-diarization-coreml`) ships only `pyannote_segmentation.mlmodelc` +
   `wespeaker_v2.mlmodelc`. Adding VAD = adding a third asset and amending the ADR 0008
   installed-only pack contract — out of scope for a "smallest slice."
2. **Network path.** `VadManager(config:)` default init downloads from HuggingFace (mirrors the
   `DiarizerModels.downloadIfNeeded` install path already in the installer). Only
   `VadManager(config:vadModel:)` with a pre-staged `.mlmodelc` avoids egress — and even that
   presupposes the asset shipped via the pack. Until that exists, wiring VAD risks rule #1.
3. **Async actor at the tap boundary.** VAD inference is `async` on an actor; the segmentation
   decision the router needs (cut here / not yet) must be synchronous-fast per buffer. The
   `processStreamingChunk` call is per-256 ms chunk and async — usable later behind the seam, but
   it adds the same FIFO/ordering concerns W1 just solved, so it deserves its own cycle + tests.

**Conclusion:** matches the task's fallback branch — *recommend an injected local
`SpeechActivitySegmenter` seam with a deterministic silence-gap fallback now, FluidAudio/Silero
backend later.*

---

## 3. Recommended smallest slice

Add a pure-function segmenter seam and drive `UtteranceWindowRouter`'s cut decision from it.

### New types (pure Swift, no I/O, `Sendable`)
```swift
protocol SpeechActivitySegmenter: Sendable {
    // Pure decision over one incoming mono block; returns whether the accumulated
    // window should be cut now. No allocation of model state, no async, no I/O.
    func update(block: [Float], sampleRate: Double) -> SegmentationDecision
    func reset()
}

enum SegmentationDecision: Equatable, Sendable {
    case accumulate            // keep buffering; window not yet at an utterance edge
    case cutAfterSilence       // trailing silence closed an utterance → cut window now
    case cutAtMaxWindow        // conservative cap hit → cut to bound latency/straddle
}
```

### Default implementation — `EnergySilenceSegmenter`
- RMS energy per block (reuse the existing RMS math from
  `SpeakerAudioPreprocessing.voicedQuality`, `FluidAudioSpeakerIdentifier.swift:35`) compared to a
  noise-floor threshold; track `speechSeconds` and `trailingSilenceSeconds` from real
  `block.count / sampleRate`.
- `cutAfterSilence` when `speechSeconds >= minSpeechSeconds` AND
  `trailingSilenceSeconds >= minSilenceSeconds`.
- `cutAtMaxWindow` when accumulated window ≥ `maxWindowSeconds` (conservative cap; keep the current
  1.0 s behavior as the cap so this slice is a strict superset, never a regression).
- Suggested defaults (Silero-aligned, tunable; cite VadSegmentationConfig as prior art):
  `minSpeechSeconds ≈ 0.25`, `minSilenceSeconds ≈ 0.40`, `maxWindowSeconds = 1.0`,
  energy threshold derived from `SpeakerMatchConfig.default.minQuality` (0.25) as a starting point.

### `UtteranceWindowRouter` change
- Replace the single `minimumChunkSamples >= threshold → cutChunk()` trigger
  (`UtteranceWindowRouter.swift:41-43`) with: feed each submitted block to the segmenter; cut on
  `cutAfterSilence` or `cutAtMaxWindow`; otherwise keep accumulating.
- `finish()` fail-open flush (`:46-57`) stays exactly as is — pending tail still appends to ASR.
- The classify-once-per-window, append-all-or-discard-all invariant (W2) is preserved; only the
  boundary selection changes from fixed-count to silence-aware.
- Inject the segmenter via init (default `EnergySilenceSegmenter`) so tests can supply a scripted
  fake. Keep `AppleSpeechLiveTranscriptionEngine` wiring (`:109-117`) unchanged except passing the
  segmenter through; `decisionWindowSeconds` becomes the segmenter's `maxWindowSeconds` cap.

### Hard-rule / ADR compliance
- No network, no analytics, no model download, no new pack asset added.
- No flight-safety claim — this reduces straddle probability, it does not guarantee speaker purity.
- Discard still only goes live behind the installed-pack gate (ADR 0008); default build fails open.
- Privacy badge, local-only default: untouched.

---

## 4. Acceptance gates (for tester / engineer)

Tester (Swift Testing, deterministic — inject the segmenter, no real clock/audio):
1. **Silence cut:** speech blocks then ≥ `minSilenceSeconds` of sub-threshold blocks → router cuts
   exactly one window at the silence edge; both pre- and post-silence groups classified separately.
2. **Max-window cap:** continuous speech with no silence → router cuts at `maxWindowSeconds`
   (never larger than the old 1.0 s window — proves no latency regression).
3. **Straddle case (the reviewer NOTE A target):** a scripted pilot-run → silence → dispatcher-run
   sequence produces **two** decision windows split at the gap, so a pilot-scored window can no
   longer carry co-located dispatcher audio into a single discard.
4. **Sub-threshold tail fails open:** speech shorter than `minSpeechSeconds` followed by `finish()`
   → all buffers appended to ASR (no silent discard).
5. **Regression guard:** the 8 existing `UtteranceWindowRouterTests` + 5 W1 `SerialBufferRouterTests`
   still pass (FIFO order + classify-once-per-window invariants intact).
6. **Determinism:** segmenter is a pure function of (blocks, sampleRate, config) — same input,
   same decisions; no `Date()`/randomness inside the core.

Engineer build gate (mac24, iPhone 17 Pro / iOS 26.4):
```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Dspeech.xcodeproj -scheme Dspeech \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  CODE_SIGNING_ALLOWED=NO build test
```
Green build+test required before commit (CLAUDE.md workflow §3).

---

## 5. Future-backend note (not this cycle)

When a VAD model asset is added to the pack contract (new ADR amending 0008), implement
`FluidAudioVADSegmenter` behind the same `SpeechActivitySegmenter` protocol, backed by
`VadManager(config:vadModel:)` (offline, staged model — never the downloading init) and
`processStreamingChunk(...)` consuming `.speechStart`/`.speechEnd` events. Operating rate is
16 kHz mono (`VadManager.sampleRate`); the repo already resamples to 16 kHz in
`SpeakerAudioPreprocessing.prepare` (`FluidAudioSpeakerIdentifier.swift:13-16`). The async-actor
ordering concerns mean it carries its own W1-style FIFO test burden.

---

## Sources

- FluidAudio README v0.14.7 — <https://raw.githubusercontent.com/FluidInference/FluidAudio/v0.14.7/README.md> (accessed 2026-05-26)
- FluidAudio VAD GettingStarted v0.14.7 — <https://raw.githubusercontent.com/FluidInference/FluidAudio/v0.14.7/Documentation/VAD/GettingStarted.md> (accessed 2026-05-26)
- FluidAudio repo — <https://github.com/FluidInference/FluidAudio>
- FluidAudio docs site — <https://docs.fluidinference.com/introduction>
- Silero VAD model repo (asset source) — `FluidInference/silero-vad-coreml`
- Apple — `SFSpeechAudioBufferRecognitionRequest` <https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest>
- Apple — `AVAudioNode.installTap(onBus:bufferSize:format:block:)` <https://developer.apple.com/documentation/avfaudio/avaudionode/installtap(onbus:buffersize:format:block:)>
- Apple — `AVAudioPCMBuffer.frameLength` <https://developer.apple.com/documentation/avfaudio/avaudiopcmbuffer/framelength>
- In-repo verification: `AppleSpeechLiveTranscriptionEngine.swift`, `UtteranceWindowRouter.swift`,
  `SerialBufferRouter.swift`, `FluidAudioSpeakerIdentifier.swift`, `SpeakerModelPackInstaller.swift`,
  `Package.resolved`, `Dspeech.xcodeproj/project.pbxproj` (branch tip `c0ea850`).

## Notion
Notion task `369dfa2b-7893-814c-be7e-e7cea26486a6` — **NOT_FOUND** (no connector reachable from this
run environment; consistent with `current-context.md` line 19). Repo run-notes + commit SHAs are the
canonical handoff.
