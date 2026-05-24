# 2026-05-24 — Pre-ASR voice-filter routing gate

Run: `dspeech-builder-20260524T190024Z-0f54bfce` · base branch `feat/local-pilot-voice-filter`.

## What changed

Added a fail-open pre-ASR routing seam so that, once a real local speaker
identifier is installed, confident pilot speech can be discarded before Apple
Speech ASR while everything uncertain still transcribes.

- `Dspeech/Core/ASR/LiveTranscriptionEngine.swift` — new `SpeechAudioBufferGate`
  protocol plus `AlwaysTranscribeSpeechAudioBufferGate` (default no-op) and
  `VoiceFilterSpeechAudioBufferGate`. The voice-filter gate calls
  `VoiceFilterPipeline.classify(samples:sampleRate:)` then
  `routeBeforeTranscription(speaker:)`; any thrown classifier (absent/disabled
  pack, unavailable identifier, capture failure) is caught and routed to ASR
  with reason `.classifierUnavailable`.
- `Dspeech/Core/VoiceFilter/PilotVoiceProfile.swift` — added
  `PreTranscriptionRoutingDecision.Reason.classifierUnavailable`.
- `Dspeech/Core/VoiceFilter/VoiceFilterPipeline.swift` —
  `routeBeforeTranscription` now returns `.transcribe(reason: .insufficientSpeech)`
  for `.insufficientSpeech` (was `.discard`), matching
  `docs/eval/local-speaker-model-pack-validation.md` so overconfident VAD/silence
  never hides clipped ATC.
- `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift` — optional injected
  `bufferGate`; input tap now routes each buffer through `appendThroughGate`.
  Default behavior is unchanged (no gate → every buffer appends). Added
  `nonisolated static monoFloatSamples(from:)` (float32 mono / averaged-stereo
  extraction). Fail-open everywhere: non-float format or empty buffer → append
  original; gate throw → append original. Only `.discard` skips the append.
- `Dspeech/App/ContentView.swift` — default app path now constructs the engine
  with a `VoiceFilterSpeechAudioBufferGate` backed by the same
  `VoiceFilterPipeline` instance used by settings. `engine:` is now optional and
  defaulted to `nil`; explicit injection (tests, previews) is unchanged.
- `DspeechTests/VoiceFilterTests.swift` — new `SpeechAudioBufferGateTests` suite
  (16 tests): pilot discards; non-pilot/mixed/insufficient-speech transcribe;
  disabled-filter / no-profile / absent-pack / disabled-pack / unavailable-identifier
  / thrown-classifier-error all fail-open to ASR; always-transcribe gate never
  discards; `routeBeforeTranscription` insufficient-speech fail-open; and four
  `monoFloatSamples` extraction cases.

No FluidAudio / WhisperKit / SPM / model-download / network code added (ADR 0008
gate respected). No `project.pbxproj` file IDs touched — new code lives in files
already in the targets.

## Source docs consulted

- FluidAudio README — https://github.com/FluidInference/FluidAudio (SPM 0.12.4,
  HuggingFace auto-download, `ModelRegistry.baseURL`); confirms deferring the dep
  in this slice.
- Apple `SFSpeechAudioBufferRecognitionRequest` —
  https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest
- Apple `AVAudioNode.installTap` —
  https://developer.apple.com/documentation/avfaudio/avaudionode/installtap(onbus:buffersize:block:)
- `docs/eval/local-speaker-model-pack-validation.md` — `insufficientSpeech` row:
  keep for STT (fail-open).

## Build / test

Tests run on mac24 (macOS 26.4.1), simulator iPhone 17 Pro OS 26.4 (exact
destination from the brief was available):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Dspeech.xcodeproj -scheme Dspeech \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
  -only-testing:DspeechTests CODE_SIGNING_ALLOWED=NO
```

Result: **TEST SUCCEEDED**. All 16 new `SpeechAudioBufferGateTests` pass;
existing `VoiceFilterPipelineTests`, `SpeakerMatcherTests`, callsign/gate,
`RouteHealthMonitorTests`, `CaptureCoordinatorTests`,
`LiveTranscriptionViewModelTests`, and model-pack-state tests remain green.
Pre-push evidence was gathered by rsyncing the worktree to a mac24 scratch dir;
the scratch dir is removed after the run.

## Commit

`24dfbdf (code SHA recorded post-amend)` — `feat(voice-filter): gate apple speech buffers before asr`,
pushed to `origin/feat/local-pilot-voice-filter`.

## Notion

Active task `https://www.notion.so/369dfa2b7893814cbe7ee7cea26486a6` still returns
`NOT_FOUND` through the connector (same as CEO observation 2026-05-24). Update not
applied; recorded here instead.

## Next highest-leverage slice

Wire the real FluidAudio-backed `LocalSpeakerIdentifier` behind the ADR 0008
acquisition/offline gates (explicit model download with `ModelRegistry.baseURL`
override, no implicit HuggingFace fetch), so `VoiceFilterSpeechAudioBufferGate`
graduates from "always fails open" to actually discarding confident pilot speech.
Until then the gate is correct but inert (classifier always unavailable →
everything transcribes).
