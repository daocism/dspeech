# W2 acceptance contract — utterance-aware pre-ASR pilot suppression

Run: `dspeech-builder-20260526T110023Z-29c9c067` · role `researcher-codebase`
Branch: `feat/local-pilot-voice-filter` · base HEAD `3bf49b8`
Date: 2026-05-26

This is a research/acceptance artifact only. No implementation files touched. It
defines the smallest implementable contract for the engineer, the seams likely to
change, the tests that must go red-before / green-after, and the guardrails that
must survive.

## 1. The W2 defect, precisely (with cites)

Reviewer residual risk **W2**: *discard must become utterance-aware, not
raw-buffer-level* (`docs/run-notes/2026-05-24-pre-asr-routing-gate.md:110`,
`.ai/project-state.md:101`, `docs/ai-kb/current-context.md:40`).

The W1 seam routes **one raw tap buffer at a time**:

- The input tap requests `bufferSize: 1024`
  (`Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:114`). At the input
  node's native format (typically 44.1/48 kHz on iOS hardware —
  `docs/research/2026-05-25-fluid-audio-speaker-identifier-contract.md:63,248`),
  1024 frames ≈ **21–23 ms** of audio.
- Each such buffer is submitted independently to `SerialBufferRouter.submit`
  (`AppleSpeechLiveTranscriptionEngine.swift:184`), classified on its own samples
  (`SerialBufferRouter.swift:48`), and then appended **or discarded** per buffer
  (`SerialBufferRouter.swift:57-62`).

The classifier it routes to needs roughly **two orders of magnitude more audio**:
FluidAudio's `minSpeechDuration` default is **1.0 s**
(`docs/research/2026-05-25-fluid-audio-speaker-identifier-contract.md:92`), and
`FluidAudioSpeakerIdentifier.classify` returns `.insufficientSpeech` whenever the
prepared clip is below `SpeakerAudioPreprocessing.minVoicedQuality`
(`Dspeech/Core/VoiceFilter/FluidAudioSpeakerIdentifier.swift:111-114`).

Two consequences:

1. **Inert-but-wrong today.** A ~23 ms buffer almost always yields
   `.insufficientSpeech` → fail-open `.transcribe`
   (`VoiceFilterPipeline.swift:169-170`). The path is safe but can never correctly
   discard — granularity makes the feature impossible, not just inaccurate.
2. **Torn transcripts the moment it isn't inert.** If any future tuning let a
   single 23 ms buffer classify confidently `.pilot`, discarding *that buffer
   alone* (`SerialBufferRouter.swift:60-61`) would punch a hole mid-syllable inside
   an utterance whose neighbouring buffers transcribe — exactly the raw-buffer-level
   hazard W2 names.

The W1 invariants are correct and must be preserved: off-`@MainActor`
classification, strict FIFO append order, fail-open on throw, no append after
`finish()` (`docs/run-notes/2026-05-26-pre-asr-serial-routing.md:20-41`;
`DspeechTests/SerialBufferRouterTests.swift`).

## 2. W2 acceptance contract (what the engineer must deliver)

Introduce a pre-ASR **utterance window** seam: accumulate consecutive tap buffers
into a coherent window of at least the classifier's minimum speech duration,
classify the **window once** over its concatenated mono-float samples, and route
**every member buffer of the window as a unit** — append all, or discard all.

**Discard is permitted only when the whole window is confidently `.pilot`.**
Everything else fails open to ASR (append all member buffers).

Normative clauses:

- **C1 — Window unit.** Buffers are grouped into windows in capture order. The
  routing decision is computed once per window from the concatenated samples and
  applied identically to all member buffers. No member buffer is ever appended or
  discarded against the window's decision.
- **C2 — Discard gate.** A window is discarded iff the window classification is a
  confident pilot decision (`SpeakerMatchDecision.pilot`) routed to
  `.discard(reason: .pilotVoice)` by the existing
  `VoiceFilterPipeline.routeBeforeTranscription`
  (`VoiceFilterPipeline.swift:162-165`). Any `.nonPilot`, `.mixed`,
  `.insufficientSpeech`, disabled filter, no profile, or thrown classifier ⇒ the
  whole window transcribes.
- **C3 — Minimum window.** A window must accumulate ≥ the classifier's minimum
  voiced duration (anchor to FluidAudio `minSpeechDuration` = 1.0 s) before a
  `.discard` may be honoured. A window that ends (at flush/stop) below that
  threshold **fails open** (append all) — never discard a window too short to
  classify.
- **C4 — FIFO preserved.** Member buffers append into
  `SFSpeechAudioBufferRecognitionRequest` in capture order, across window
  boundaries. The W1 serial guarantee survives: a slow window classification may
  not let a later window's buffers overtake an earlier window's.
- **C5 — Flush on stop.** `finish()` / `cleanup()` must flush any partially
  accumulated window by appending its buffered audio (fail open). Buffered audio is
  never silently dropped on stop, and no buffer appends after `finish()`
  (`SerialBufferRouter.swift:32-35`, `:56`).
- **C6 — Fail-open on throw.** A classifier throw on a window appends every member
  buffer, order preserved (mirrors `SerialBufferRouter.swift:49-53`).

The window boundary policy (fixed-duration accumulation vs. VAD silence-gap
segmentation) is left to the engineer; C3's minimum-duration floor and C2's
whole-window-pilot rule are the binding constraints. A fixed ≥1.0 s accumulation
window is the minimal honest implementation; VAD-segmented windows
(`...speaker-identifier-contract.md:148-157`) are an acceptable richer variant if
they still satisfy C1–C6. Internal algorithm choice is the engineer's.

## 3. Minimal production seams likely to change

- **NEW** `Dspeech/Core/ASR/UtteranceWindowRouter.swift` (or
  `UtteranceWindowAccumulator.swift`) — accumulates `(buffer, samples, sampleRate)`
  into windows and routes each window as a unit. Shape mirrors `SerialBufferRouter`
  (injected `classify` over concatenated samples + injected `append` per member
  buffer) so W1's testable-closure pattern and fail-open/FIFO guarantees carry over.
  Cleanest path: this seam **wraps or replaces** `SerialBufferRouter`; either is
  acceptable provided W1 tests stay green.
- `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift` — `routeBuffer`
  (`:176-185`) feeds the window seam instead of submitting each buffer directly;
  `cleanup()` (`:236-250`) flushes the window before `finish()`.
- `Dspeech/Core/ASR/SerialBufferRouter.swift` — optional: generalise to accept a
  window (array of buffers + concatenated samples) rather than a single buffer, **or**
  keep it unchanged and layer the accumulator above it.
- **NEW** `DspeechTests/UtteranceWindowRouterTests.swift` — Swift Testing suite
  (RED first), structured like `SerialBufferRouterTests` with a deterministic gated
  classifier double (no sleeps/wall-clock).

Out of scope / do **not** touch: `PreTranscriptionRoutingDecision.Reason`
(`PilotVoiceProfile.swift:61-74`) — existing reasons suffice; add a window-specific
reason only if a test demands it. No `project.pbxproj` ID renumbering (append new
file entries only). No FluidAudio/SPM/network/model-download additions. No billing.

## 4. Tests: red before implementation, green after

New suite `UtteranceWindowRouterTests` (and existing `SerialBufferRouterTests`
must stay green — W1 regression guard).

1. **`discardsWholeWindowWhenEveryBufferIsPilot`** — a window whose constituent
   buffers all classify `.pilot` discards **all** member buffers (zero appends).
   (C1, C2)
2. **`failsOpenEntireWindowWhenAnyPartIsNonPilot`** — a window mixing pilot and
   non-pilot/mixed content appends **every** member buffer; nothing dropped. (C2)
3. **`isolatedPilotBufferIsNotDroppedInIsolation`** — the W2 regression: a single
   short pilot-leaning buffer surrounded by dispatcher audio in the same window
   transcribes (window-level decision, fail open). Pin this against the old
   per-buffer behaviour. (C1, C2)
4. **`subThresholdWindowFailsOpenNeverDiscards`** — a window that ends below the
   minimum voiced duration appends its buffers even if its (unreliable)
   classification leaned pilot. (C3)
5. **`appendsWindowsInCaptureOrderWhenLaterWindowClassifiesFirst`** — FIFO across
   windows under reordered completion (the W1 invariant lifted to windows). (C4)
6. **`flushOnFinishAppendsPartialWindow`** — buffers accumulated but not yet
   windowed at `finish()` are appended (fail open), and no buffer appends after
   `finish()`. (C5)
7. **`classifierThrowOnWindowAppendsAllMembersInOrder`** — a thrown window
   classification fails open: all member buffers append, order preserved. (C6)
8. **`disabledFilterOrNoProfileTranscribesEveryWindow`** — gate-level fail-open
   (`VoiceFilterPipeline.routeBeforeTranscription` for `.filterDisabled` /
   `.noPilotProfile`, `:160-161`) means every window transcribes regardless of
   window content. (guardrail)

## 5. Guardrails (must hold after implementation)

- **Fail open to ASR** on: uncertainty, classifier error, missing/disabled model
  pack, disabled filter, no pilot profile, mixed speaker, insufficient speech, and
  sub-threshold or partial (flushed) windows. Only a confident whole-window pilot
  classification discards. (CLAUDE.md hard-rule 2/3; C2/C3/C5/C6)
- **No network/cloud path.** No egress of audio, transcripts, or metadata; no
  FluidAudio/SPM/HuggingFace fetch added. `PrivacyMode.localOnly` default unchanged.
  (CLAUDE.md hard-rule 1; ADR 0002)
- **No certified / safety-critical correctness claim** in code, comments, run
  notes, or copy. (ADR 0008; `docs/run-notes/2026-05-26-pre-asr-serial-routing.md:48`)
- **Source audio / replay remains canonical** for debugging — discard affects only
  what reaches Apple Speech, not any retained source-of-truth recording lane.
- **Real hardware / real ATC samples NOT required** — windowing is provable with the
  deterministic gated-classifier double, as W1's tests already demonstrate.

## 6. Build / test command (engineer)

```bash
ssh mac24 'cd /Users/andre/projects/dspeech-ios && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Dspeech.xcodeproj -scheme Dspeech \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
    -only-testing:DspeechTests CODE_SIGNING_ALLOWED=NO test'
```

## 7. Sources consulted

- `Dspeech/Core/ASR/SerialBufferRouter.swift`,
  `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift`,
  `Dspeech/Core/ASR/LiveTranscriptionEngine.swift`
- `Dspeech/Core/VoiceFilter/VoiceFilterPipeline.swift`,
  `PilotVoiceProfile.swift`, `ATCTranscriptGate.swift`,
  `FluidAudioSpeakerIdentifier.swift`, `LocalSpeakerIdentifier.swift`
- `DspeechTests/SerialBufferRouterTests.swift`, `DspeechTests/VoiceFilterTests.swift`
- `docs/run-notes/2026-05-26-pre-asr-serial-routing.md`,
  `docs/run-notes/2026-05-24-pre-asr-routing-gate.md`
- `docs/research/2026-05-25-fluid-audio-speaker-identifier-contract.md`
  (FluidAudio `minSpeechDuration: 1.0`, 16 kHz mono Float32, VAD segmentation)
- `.ai/project-state.md`, `docs/ai-kb/current-context.md`, ADR 0002 / 0007 / 0008
- Apple `SFSpeechAudioBufferRecognitionRequest` —
  https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest
  (incremental `append(_:)`; the routing seam controls which buffers are appended)
- Apple "Recognizing speech in live audio" —
  https://developer.apple.com/documentation/Speech/recognizing-speech-in-live-audio

## 8. Notion

Active task `369dfa2b-7893-814c-be7e-e7cea26486a6` returned `NOT_FOUND` from the
connector during CEO inspection (consistent with the 2026-05-24 observation). Repo
artifacts are canonical; this file is the handoff of record.
