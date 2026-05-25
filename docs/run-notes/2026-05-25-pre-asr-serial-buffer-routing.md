# 2026-05-25 — Pre-ASR serial buffer routing (reviewer W1 hardening)

Run: `dspeech-supervisor-20260525T203100Z-a08f1596` · base branch `feat/local-pilot-voice-filter` · branch `fix/pre-asr-serial-buffer-routing`.

## Why

Reviewer W1: the input tap wrapped every captured buffer in its own
`Task { @MainActor in await appendThroughGate(buffer) }`. Independently
scheduled tasks have no guaranteed start order, so once pre-ASR speaker
classification becomes non-trivial, buffers could append to
`SFSpeechAudioBufferRecognitionRequest` out of capture order — corrupting the
transcript before any discard policy is even trusted.

## What changed

- `Dspeech/Core/ASR/LiveTranscriptionEngine.swift` — added
  `AudioBufferRouting { transcribe, discard }` and a generic
  `SerialAudioRoutingQueue<Element: Sendable>`. The queue exposes a
  `nonisolated submit(_:)` callable from the realtime capture thread (yields
  into an `AsyncStream`, which preserves enqueue order) and a single
  `@MainActor` consumer loop that routes one element fully — decision then any
  append — before pulling the next. That single sequential consumer **is** the
  serialization boundary. `finish()` ends the stream and cancels the consumer.
- `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift` — the tap no
  longer spawns a per-buffer `Task`; it calls `queue.submit(SendableAudioBuffer(buffer))`
  directly. `appendThroughGate` was split into a decision-only `routeBuffer(_:)
  async -> AudioBufferRouting` (gate-nil / unsupported-format / classifier-throw
  all fail open to `.transcribe`; only `.discard` suppresses) and the queue's
  append closure `self?.request?.append(...)`. `cleanup()` now calls
  `routingQueue?.finish()` before niling `request`, and the append closure's
  `request?` guard means a late in-flight buffer cannot append to a stale
  request. Added the `SendableAudioBuffer` `@unchecked Sendable` box (documented:
  single in-order hand-off from capture thread to the main-actor consumer, never
  mutated concurrently).

## Public behavior — unchanged

No gate → append everything. Unsupported sample format → append. Classifier
error → append. `.discard` suppresses only the current pilot buffer. Default
`AppleSpeechLiveTranscriptionEngine(bufferGate:)` and static `monoFloatSamples`
signatures are untouched; no consumer (`ContentView`, `VoiceEnrollmentRecorder`,
view-model/fake-engine tests) changed.

## Tests (`DspeechTests/VoiceFilterTests.swift`, additive only)

- `SerialAudioRoutingQueueTests` — capture-order preserved when an earlier
  element routes slower (differential `Task.yield`, deterministic), discarded
  elements never append, fail-open routing still appends in order, and
  `submit` after `finish` is ignored (no append to a torn-down queue).
- `AppleSpeechRoutingTests` — `routeBuffer` returns `.transcribe` for no gate /
  unsupported int16 format / thrown classifier / non-pilot, and `.discard` for a
  confident pilot, using real `AVAudioPCMBuffer`s + scripted identifiers.

## Scope deliberately NOT taken

Classification still executes on the main actor: `SpeechAudioBufferGate` and
`VoiceFilterPipeline` remain `@MainActor`. Moving the embedding/classify work
off the main actor is a broad actor/protocol migration (it would re-isolate the
gate protocol, the pipeline, and the `LocalSpeakerIdentifier` surface that the
UI also reads) and is out of scope for this slice per the mission constraint.
The serialization boundary delivered here removes the out-of-order-append hazard
regardless of where classification runs; off-main classification is a follow-up.

## Verification

Build/test must run on mac24 (no Xcode on ubuntu-vm):

```bash
ssh mac24 'cd /Users/andre/projects/dspeech-ios && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Dspeech.xcodeproj -scheme Dspeech \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
    CODE_SIGNING_ALLOWED=NO build test'
```
