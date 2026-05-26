# Pre-ASR serial buffer routing (reviewer W1)

Date: 2026-05-26
Branch: `feat/local-pilot-voice-filter`
Run: `dspeech-builder-20260526T070010Z-12e3f037` · role `engineer-backend`

## What shipped

`SerialBufferRouter<Buffer>` (`Dspeech/Core/ASR/SerialBufferRouter.swift`), a
`@MainActor` seam that satisfies reviewer **W1**: captured audio is classified
**off `@MainActor`** while append/discard decisions are applied **strictly in
capture (FIFO) order**. A slow first classification can no longer let a later
buffer overtake it into the Apple Speech recognition request.

`AppleSpeechLiveTranscriptionEngine` now submits each tap buffer to the router
(`submit`) instead of spawning an unordered per-buffer `Task` that awaited the
gate and appended independently. The router drains one item at a time: it does
not start classifying buffer *n+1* until buffer *n*'s decision has resolved.

## Why this is correct, not just green

- **Off-main classification.** The router's `classify` closure is `@Sendable`
  and routes through the gate → `VoiceFilterPipeline.classify` →
  `LocalSpeakerIdentifier.classify`, which is a nonisolated `async` call on a
  `Sendable` struct — the heavy FluidAudio embedding work runs off `@MainActor`.
  Only the lightweight `enabled`/`profiles` reads touch the main actor.
- **FIFO under reordered completion.** The serial drain loop processes the queue
  in `submit` order regardless of which classification *would* finish first
  (`SerialBufferRouterTests.appendsInSubmitOrderWhenLaterBufferClassifiesFirst`,
  `laterBufferWaitsForEarlierDiscardDecision`).
- **Fail open.** A thrown classifier error becomes `.transcribe(.classifierUnavailable)`
  → the buffer is appended, never silently dropped, and order is preserved
  (`classifierErrorAppendsBufferAndPreservesOrder`,
  `failOpenTranscribeDecisionsNeverDiscard`). This composes with the existing
  fail-open behavior in `VoiceFilterSpeechAudioBufferGate.route` for
  absent/disabled packs and unavailable identifiers.
- **No stale request.** `cleanup()` calls `router.finish()` before nil-ing the
  request; `finish()` clears the queue and blocks post-stop submissions, and the
  `append` closure reads `self?.request` weakly/live, so a buffer still
  classifying off-main can never append into an ended/released
  `SFSpeechAudioBufferRecognitionRequest` (`finishPreventsFutureAppends`).

## Scope discipline

In scope only: the serial pre-ASR routing seam. **Not** touched: utterance-aware
discard (W2), replay fixtures, hardware docs, App Store work, billing. Privacy
unchanged — no audio/transcript/metadata egress, no cloud/network paths added.
Source audio/replay remains canonical for debugging; this is **not** a
flight-safety guarantee (ADR 0008).

## Verification

Run on mac24 against origin `feat/local-pilot-voice-filter` (HEAD `541353d`):

```
ssh mac24 'cd /Users/andre/projects/dspeech-ios && git fetch/checkout/pull --ff-only &&
  xcodebuild -project Dspeech.xcodeproj -scheme Dspeech \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
    -only-testing:DspeechTests CODE_SIGNING_ALLOWED=NO test'
```

Result: `** TEST SUCCEEDED **`. All five `SerialBufferRouterTests` pass; full
`DspeechTests` suite green; no compiler errors or warnings on the changed files.

## Residual risk

- Tap → `submit` still hops via `Task { @MainActor }`. The router guarantees
  FIFO over its *submit* order; if the runtime ever reorders those MainActor
  hops the submit order could differ from capture order. In practice audio tap
  callbacks are serial and the hops enqueue in order. A fully reorder-proof tap
  path is out of W1 scope.
- Off-main benefit depends on the identifier staying nonisolated; a future
  `@MainActor` identifier would pull classification back on-main.
