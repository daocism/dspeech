# Utterance-aware pre-ASR pilot suppression (W2)

Run: `dspeech-builder-20260526T110023Z-29c9c067` · role `engineer-generic`
Branch: `feat/local-pilot-voice-filter`
Date: 2026-05-26

Implements the W2 acceptance contract
(`.ai/runs/dspeech-builder-20260526T110023Z-29c9c067-researcher-codebase.md`):
the pre-ASR discard decision is now utterance-window-level, not raw-tap-buffer
level, so an isolated buffer the classifier mislabels as pilot can no longer
punch a hole in an ATC utterance.

## What changed

- **NEW `Dspeech/Core/ASR/UtteranceWindowRouter.swift`** — accumulates
  `(buffer, samples, sampleRate)` tap buffers into a decision window of at least
  `minimumChunkSamples`, classifies the **whole concatenated window once**, and
  applies that single decision to **every member buffer as a unit** (append all,
  or discard all). It wraps the existing `SerialBufferRouter<[Buffer]>` so the W1
  FIFO / off-`@MainActor` / fail-open-on-throw / no-append-after-`finish()`
  guarantees are reused rather than reimplemented. A sub-threshold window is never
  classified; on `finish()` the pending tail is flushed (appended, fail open).
- **`Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift`** — the buffer
  gate now feeds an `UtteranceWindowRouter<AVAudioPCMBuffer>` whose window size is
  `sampleRate × decisionWindowSeconds` (1.0 s, anchored to FluidAudio's
  `minSpeechDuration`). `cleanup()` already calls `router.finish()` before
  `request.endAudio()`, so the partial-window flush precedes the request ending.
- **NEW `DspeechTests/UtteranceWindowRouterTests.swift`** — Swift Testing suite,
  RED before implementation, deterministic gated-classifier double (no
  sleeps/wall-clock), structured like `SerialBufferRouterTests`.
- `Dspeech.xcodeproj/project.pbxproj` — appended file/group/build entries for the
  two new files (IDs `…0154`–`…0157`; no existing IDs renumbered).

`SerialBufferRouter` and its tests are unchanged — kept as the serial core the
window router builds on, so the W1 regression guard stays green.

## Contract coverage (C1–C6)

| Clause | Test |
| --- | --- |
| C1 window unit / C2 discard gate | `coherentPilotWindowIsDiscardedAsUnit`, `transcribeWindowAppendsAllBuffersInOrder` |
| C2 isolated pilot fails open | `subThresholdWindowIsNeverDiscarded`, `transcribeWindowAppendsAllBuffersInOrder` |
| C3 minimum window | `subThresholdWindowIsNeverDiscarded` |
| C4 FIFO across windows | `chunksAppliedInSubmitOrder` |
| C5 flush on stop / no append after finish | `finishFlushesPendingTailInOrder`, `finishPreventsFutureAppends`, `inFlightChunkDoesNotAppendAfterFinish` |
| C6 fail-open on throw | `classifierErrorAppendsWindowAsUnit` |

C-level disabled-filter / no-profile fail-open remains pinned at the pipeline
layer by the existing `SpeechAudioBufferGateTests` in `VoiceFilterTests.swift`.

## Tests run and result

Ran on mac24 (the only Xcode host; ubuntu-vm has no Xcode):

```bash
ssh mac24 'cd /Users/andre/projects/dspeech-ios && git fetch origin && \
  git checkout feat/local-pilot-voice-filter && \
  git pull --ff-only origin feat/local-pilot-voice-filter && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Dspeech.xcodeproj -scheme Dspeech \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
    -only-testing:DspeechTests CODE_SIGNING_ALLOWED=NO test'
```

Result: **`** TEST SUCCEEDED **`** at branch tip `aee9c8c`.

- All 8 `UtteranceWindowRouterTests` passed:
  `subThresholdWindowIsNeverDiscarded`, `coherentPilotWindowIsDiscardedAsUnit`,
  `transcribeWindowAppendsAllBuffersInOrder`, `classifierErrorAppendsWindowAsUnit`,
  `chunksAppliedInSubmitOrder`, `finishFlushesPendingTailInOrder`,
  `finishPreventsFutureAppends`, `inFlightChunkDoesNotAppendAfterFinish`.
- The W1 regression guard `SerialBufferRouterTests` (5 cases) stayed green.
- The rest of the `DspeechTests` domain suite (VoiceFilter, RouteHealth,
  CaptureCoordinator, LiveTranscriptionViewModel, etc.) stayed green.

## Residual risk

- **In-flight window dropped at stop.** If a complete window is still being
  classified off-`@MainActor` when `finish()` is called, that window is dropped
  (not appended) — the inner serial router's guard prevents any append after the
  request ends. This is the pre-existing W1 stop-time behavior; only the
  not-yet-windowed tail is flushed fail-open. Bounded to the audio in flight at the
  moment of stop.
- **Fixed-duration window, not VAD-segmented.** The window boundary is a fixed
  1.0 s sample count, the minimal honest implementation the contract permits. A
  VAD silence-gap segmentation (richer variant) is left for a later slice; it would
  tighten utterance boundaries but is not required to satisfy C1–C6.
- **Window size assumes native tap sample rate.** `minimumChunkSamples` is derived
  from the input node's `recordingFormat.sampleRate` at `start()`; a mid-session
  route change is already torn down and restarted by the engine, so the window size
  is recomputed on the next `start()`.

## Safety statement

No safety, certification, or airworthiness claim is made. Discard affects only
which buffers reach Apple Speech; it does not alter any retained source audio lane.
Local-only behavior is unchanged — no network, cloud, analytics, or model-download
path is added. Fail-open is the default on every uncertainty (disabled filter, no
profile, sub-threshold window, mixed/insufficient speech, classifier throw, stop
flush).
