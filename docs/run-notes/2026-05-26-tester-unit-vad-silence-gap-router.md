# tester-unit — VAD/silence-gap utterance router contract (test-first, RED)

- Run: `dspeech-builder-20260526T190043Z-8cec065d`
- Role: tester-unit
- Branch: `feat/local-pilot-voice-filter`
- Commit: `bb6af9b` (on top of researcher-docs `615fcc9`)
- Depends on: researcher-docs source pack `.ai/runs/dspeech-builder-20260526T190043Z-8cec065d-researcher-docs.md`
- Scope: test-only. **No production Swift edited. No pbxproj edited.**

## What changed

Rewrote `DspeechTests/UtteranceWindowRouterTests.swift` from the fixed-count
(`minimumChunkSamples`) seam to the injected `SpeechActivitySegmenter` seam the
researcher recommended. Folded the default-segmenter suite into the same
already-registered test file (no new pbxproj entry needed).

## Seam pinned for the engineer (RED until landed)

```swift
protocol SpeechActivitySegmenter: Sendable {
    func update(block: [Float], sampleRate: Double) -> SegmentationDecision
    func reset()
}

enum SegmentationDecision: Equatable, Sendable {
    case accumulate
    case cutAfterSilence
    case cutAtMaxWindow
}

@MainActor
final class UtteranceWindowRouter<Buffer> {
    init(
        segmenter: SpeechActivitySegmenter,                       // replaces minimumChunkSamples
        classify: @escaping @Sendable ([Float], Double) async throws -> PreTranscriptionRoutingDecision,
        append: @escaping (Buffer) -> Void
    )
    func submit(_ buffer: Buffer, samples: [Float], sampleRate: Double)
    func finish()
}

final class EnergySilenceSegmenter: SpeechActivitySegmenter {     // default impl
    init(minSpeechSeconds: Double, minSilenceSeconds: Double, maxWindowSeconds: Double)
}
```

Router behavior the tests require: feed each submitted block to
`segmenter.update`; cut the accumulated window on `.cutAfterSilence` or
`.cutAtMaxWindow` (classify once via the inner `SerialBufferRouter`, append-all
or discard-all); call `segmenter.reset()` after each cut; on `.accumulate` keep
buffering; `finish()` flushes the pending tail fail-open and blocks any
post-finish / in-flight append (W1/W2 invariant unchanged).

Note: the engineer must register the new production file(s)
(`SpeechActivitySegmenter.swift` / `EnergySilenceSegmenter.swift`) in
`Dspeech.xcodeproj/project.pbxproj` — appending new file entries only.

## Tests added (15)

`UtteranceWindowRouterTests` (router seam, scripted-segmenter, gated classify):
1. `windowClassifiedOnlyAfterSilenceEdgeNotSampleCount` — req #1
2. `twoBurstsSplitBySilenceBecomeTwoDecisionsInOrder` — req #2 (FIFO)
3. `pilotThenNonPilotUtteranceKeepsSecondUtterance` — req #3 (NOTE A straddle fix)
4. `continuousSpeechCutByMaxWindowCap` — req #4
5. `segmenterResetAfterEachCutWindow` — req #5
6. `silenceOnlyPendingTailFailsOpenOnFinish` — req #5/#6 fail-open
7. `classifierErrorFailsOpenAppendingWholeWindow` — req #6
8. `windowsAppliedInSubmitOrderWhenLaterClassifiesFirst` — FIFO invariant
9. `bufferSubmittedAfterFinishIsNeverAppended` — req #7
10. `inFlightWindowDoesNotAppendAfterFinish` — req #7

`EnergySilenceSegmenterTests` (default RMS detector, formula-agnostic, loud=1.0/silent=0.0):
11. `silenceWithoutPrecedingSpeechNeverCuts`
12. `trailingSilenceAfterSpeechCutsWindow`
13. `continuousSpeechCutsAtMaxWindowCap`
14. `briefSpeechBelowMinSpeechDoesNotCutAfterSilence`
15. `deterministicForSameInputSequence` + `resetClearsAccumulatedState`

All deterministic: no real clock, randomness, network, audio files, or
FluidAudio model download. Injected scripted segmenter / gated classify only.

## RED evidence (mac24, iPhone 17 Pro / iOS 26.4, branch tip `bb6af9b`)

```
xcodebuild ... -only-testing:DspeechTests ... test
EXIT=65 → ** TEST FAILED ** (build phase)
49 compile errors, ALL in UtteranceWindowRouterTests.swift, 0 elsewhere:
  - cannot find type 'SpeechActivitySegmenter' in scope
  - cannot find type 'SegmentationDecision' in scope
  - cannot find type 'EnergySilenceSegmenter' in scope
  - incorrect argument label in call (have 'segmenter:classify:append:',
    expected 'minimumChunkSamples:classify:append:')
  - reference to member 'accumulate'/'cutAfterSilence'/'cutAtMaxWindow'
    cannot be resolved without a contextual type
```

This is the expected RED: production code is untouched and still compiles; the
only failure is the absent seam. Tests go GREEN once the engineer lands the
protocol/enum/default impl and the `segmenter:` initializer.

## Handoff to engineer

Implement the seam above against these tests. Strict superset of W2 (keep
`maxWindowSeconds` = the old 1.0 s cap so no latency regression). Discard stays
behind the installed-pack gate (ADR 0008); default build still fails open. No
network, no new model asset this cycle (FluidAudio Silero VAD deferred —
researcher §2/§5). Build gate: full `DspeechTests` green on mac24.
