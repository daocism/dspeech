import Foundation
import Synchronization
import Testing
@testable import Dspeech

// Behavior contract for the VAD / silence-gap utterance-segmentation seam.
//
// W2 cut the discard decision window at a *fixed sample count*
// (`minimumChunkSamples`, ~1.0 s of audio). A window that straddles a
// pilot→dispatcher PTT transition could therefore discard up to ~1 s of
// co-located dispatcher speech (reviewer NOTE A). This iteration replaces the
// fixed-count cut with an injected `SpeechActivitySegmenter`: the router feeds
// every submitted block to the segmenter and only cuts a decision window when
// the segmenter reports a *trailing-silence utterance edge* (`.cutAfterSilence`)
// or a *conservative max-window cap* (`.cutAtMaxWindow`). Below an utterance
// edge the window keeps accumulating; on `finish()` unresolved submitted audio
// is flushed (fail open) in FIFO order and late classifier results are ignored
// so no buffer is appended twice.
//
// These tests drive a seam that does not yet exist in production; they are RED
// (compile failure: "cannot find type 'SpeechActivitySegmenter' in scope",
// "cannot find 'SegmentationDecision'", "cannot find 'EnergySilenceSegmenter'",
// and the changed `UtteranceWindowRouter` initializer) until the engineer lands
// it. The seam is exercised through injected closures + a scripted segmenter
// rather than a real `SFSpeechAudioBufferRecognitionRequest` or real audio:
//
//   protocol SpeechActivitySegmenter: Sendable {
//       func update(block: [Float], sampleRate: Double) -> SegmentationDecision
//       func reset()
//   }
//
//   enum SegmentationDecision: Equatable, Sendable {
//       case accumulate          // not yet at an utterance edge — keep buffering
//       case cutAfterSilence     // trailing silence closed an utterance — cut now
//       case cutAtMaxWindow      // conservative cap hit — cut to bound latency/straddle
//   }
//
//   @MainActor
//   final class UtteranceWindowRouter<Buffer> {
//       init(
//           segmenter: SpeechActivitySegmenter,
//           classify: @escaping @Sendable ([Float], Double) async throws -> PreTranscriptionRoutingDecision,
//           append: @escaping (Buffer) -> Void
//       )
//       func submit(_ buffer: Buffer, samples: [Float], sampleRate: Double)
//       func finish()
//   }
//
// Contract the engineer must satisfy:
//   1. A window is classified only after the segmenter reports an utterance edge
//      (`.cutAfterSilence`/`.cutAtMaxWindow`), never merely because some sample
//      count was reached.
//   2. Two speech bursts split by a silence edge become two separate classifier
//      decisions, applied in submit (FIFO) order.
//   3. A pilot-labeled first utterance followed by a non-pilot second utterance
//      keeps the second utterance — it is not co-discarded just because both
//      would have fit inside the old fixed 1.0 s window.
//   4. A continuous speech region with no silence is cut by `.cutAtMaxWindow`, so
//      the window never grows unbounded.
//   5. The segmenter is reset after each cut so utterance state does not bleed
//      across windows.
//   6. A sub-threshold / silence-only pending tail is flushed (appended) on
//      `finish()`, never silently discarded.
//   7. A classifier throw still fails open: the whole window is appended.
//   8. `finish()` finalizes submitted audio in FIFO order: any cut window still
//      classifying fail-opens before a later pending tail, late classifier results
//      are ignored, and buffers submitted after finish are never appended.
@MainActor
struct UtteranceWindowRouterTests {

    // Deterministic test double: classification suspends until the test releases
    // each token, and records an ordered event log so serialization is provable
    // without sleeps or wall-clock timing. The token is the first sample of the
    // concatenated chunk; padding samples are zero.
    actor WindowGate {
        enum Event: Equatable, Sendable {
            case start(Int)
            case finish(Int)
        }

        private(set) var events: [Event] = []
        private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
        private var released: Set<Int> = []

        func begin(_ token: Int) async {
            events.append(.start(token))
            if released.contains(token) { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pending[token] = continuation
            }
        }

        func end(_ token: Int) {
            events.append(.finish(token))
        }

        func release(_ token: Int) {
            released.insert(token)
            pending.removeValue(forKey: token)?.resume()
        }

        func snapshot() -> [Event] { events }
    }

    // A buffer carries a token in its first sample and `count` total samples so a
    // window of known size can be built from a known number of buffers.
    nonisolated private static func samples(token: Int, count: Int) -> [Float] {
        var values = [Float](repeating: 0, count: max(count, 1))
        values[0] = Float(token)
        return values
    }

    nonisolated private static func token(from samples: [Float]) -> Int {
        Int(samples.first ?? -1)
    }

    nonisolated private static func gatedClassify(
        gate: WindowGate,
        decisions: [Int: PreTranscriptionRoutingDecision],
        errorTokens: Set<Int> = []
    ) -> @Sendable ([Float], Double) async throws -> PreTranscriptionRoutingDecision {
        { samples, _ in
            let token = UtteranceWindowRouterTests.token(from: samples)
            await gate.begin(token)
            await gate.end(token)
            if errorTokens.contains(token) {
                throw LocalSpeakerIdentifierError.captureFailed(reason: "scripted-\(token)")
            }
            return decisions[token] ?? .transcribe(reason: .nonPilotVoice)
        }
    }

    @Test("should classify a window only after a trailing-silence edge, not after a sample count")
    func windowClassifiedOnlyAfterSilenceEdgeNotSampleCount() async {
        let gate = WindowGate()
        let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
        // Tokens 1 and 2 are mid-utterance (.accumulate); token 3 carries the
        // trailing-silence edge that closes the window.
        let segmenter = ScriptedSegmenter([
            1: .accumulate,
            2: .accumulate,
            3: .cutAfterSilence,
        ])
        let router = UtteranceWindowRouter<Int>(
            segmenter: segmenter,
            classify: Self.gatedClassify(gate: gate, decisions: [1: .transcribe(reason: .nonPilotVoice)]),
            append: { appendContinuation.yield($0) }
        )

        // Large blocks: under the old fixed-count rule these would have cut after
        // the first buffer. The segmenter says keep accumulating, so nothing is
        // classified yet.
        router.submit(1, samples: Self.samples(token: 1, count: 4_000), sampleRate: 16_000)
        router.submit(2, samples: Self.samples(token: 2, count: 4_000), sampleRate: 16_000)
        for _ in 0..<50 { await Task.yield() }
        #expect(await gate.snapshot() == [])

        // The silence edge arrives → the whole [1,2,3] window is classified once.
        router.submit(3, samples: Self.samples(token: 3, count: 4_000), sampleRate: 16_000)
        await gate.release(1)

        var iterator = appended.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 2)
        #expect(await iterator.next() == 3)
        #expect(await gate.snapshot() == [.start(1), .finish(1)])
    }

    @Test("should produce two separate decisions when two bursts are split by a silence edge")
    func twoBurstsSplitBySilenceBecomeTwoDecisionsInOrder() async {
        let gate = WindowGate()
        let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
        // Burst A = tokens 1,2 (edge at 2); burst B = tokens 3,4 (edge at 4).
        let segmenter = ScriptedSegmenter([
            1: .accumulate, 2: .cutAfterSilence,
            3: .accumulate, 4: .cutAfterSilence,
        ])
        let router = UtteranceWindowRouter<Int>(
            segmenter: segmenter,
            classify: Self.gatedClassify(
                gate: gate,
                decisions: [
                    1: .transcribe(reason: .nonPilotVoice),
                    3: .transcribe(reason: .nonPilotVoice),
                ]
            ),
            append: { appendContinuation.yield($0) }
        )

        router.submit(1, samples: Self.samples(token: 1, count: 6), sampleRate: 16_000)
        router.submit(2, samples: Self.samples(token: 2, count: 6), sampleRate: 16_000)
        router.submit(3, samples: Self.samples(token: 3, count: 6), sampleRate: 16_000)
        router.submit(4, samples: Self.samples(token: 4, count: 6), sampleRate: 16_000)

        await gate.release(1)
        await gate.release(3)

        var iterator = appended.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 2)
        #expect(await iterator.next() == 3)
        #expect(await iterator.next() == 4)
        // Two windows, classified once each, in submit order.
        #expect(await gate.snapshot() == [.start(1), .finish(1), .start(3), .finish(3)])
    }

    @Test("should keep the non-pilot second utterance when the first utterance is pilot")
    func pilotThenNonPilotUtteranceKeepsSecondUtterance() async {
        let gate = WindowGate()
        let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
        // Window A (1,2) is pilot → discard. Window B (3,4) is non-pilot → keep.
        // Under the old fixed 1.0 s window all four small buffers would have been
        // one chunk and discarded together; the silence edge splits them.
        let segmenter = ScriptedSegmenter([
            1: .accumulate, 2: .cutAfterSilence,
            3: .accumulate, 4: .cutAfterSilence,
        ])
        let router = UtteranceWindowRouter<Int>(
            segmenter: segmenter,
            classify: Self.gatedClassify(
                gate: gate,
                decisions: [
                    1: .discard(reason: .pilotVoice),
                    3: .transcribe(reason: .nonPilotVoice),
                ]
            ),
            append: { appendContinuation.yield($0) }
        )

        router.submit(1, samples: Self.samples(token: 1, count: 6), sampleRate: 16_000)
        router.submit(2, samples: Self.samples(token: 2, count: 6), sampleRate: 16_000)
        router.submit(3, samples: Self.samples(token: 3, count: 6), sampleRate: 16_000)
        router.submit(4, samples: Self.samples(token: 4, count: 6), sampleRate: 16_000)

        await gate.release(1)
        await gate.release(3)

        var iterator = appended.makeAsyncIterator()
        var appendedTokens: [Int] = []
        if let firstToken = await iterator.next() { appendedTokens.append(firstToken) }
        if let secondToken = await iterator.next() { appendedTokens.append(secondToken) }
        // Pilot window dropped as a unit; the second utterance survives intact.
        #expect(appendedTokens == [3, 4])
        appendContinuation.finish()
    }

    @Test("should cut a continuous no-silence region at the max-window cap")
    func continuousSpeechCutByMaxWindowCap() async {
        let gate = WindowGate()
        let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
        // No silence ever; the cap closes the window so it cannot grow unbounded.
        let segmenter = ScriptedSegmenter([
            1: .accumulate,
            2: .accumulate,
            3: .cutAtMaxWindow,
        ])
        let router = UtteranceWindowRouter<Int>(
            segmenter: segmenter,
            classify: Self.gatedClassify(gate: gate, decisions: [1: .transcribe(reason: .nonPilotVoice)]),
            append: { appendContinuation.yield($0) }
        )

        router.submit(1, samples: Self.samples(token: 1, count: 6), sampleRate: 16_000)
        router.submit(2, samples: Self.samples(token: 2, count: 6), sampleRate: 16_000)
        router.submit(3, samples: Self.samples(token: 3, count: 6), sampleRate: 16_000)
        await gate.release(1)

        var iterator = appended.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 2)
        #expect(await iterator.next() == 3)
        #expect(await gate.snapshot() == [.start(1), .finish(1)])
    }

    @Test("should reset the segmenter after each cut window")
    func segmenterResetAfterEachCutWindow() async {
        let gate = WindowGate()
        let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
        let segmenter = ScriptedSegmenter([
            1: .accumulate, 2: .cutAfterSilence,
            3: .accumulate, 4: .cutAtMaxWindow,
        ])
        let router = UtteranceWindowRouter<Int>(
            segmenter: segmenter,
            classify: Self.gatedClassify(
                gate: gate,
                decisions: [
                    1: .transcribe(reason: .nonPilotVoice),
                    3: .transcribe(reason: .nonPilotVoice),
                ]
            ),
            append: { appendContinuation.yield($0) }
        )

        router.submit(1, samples: Self.samples(token: 1, count: 6), sampleRate: 16_000)
        router.submit(2, samples: Self.samples(token: 2, count: 6), sampleRate: 16_000)
        router.submit(3, samples: Self.samples(token: 3, count: 6), sampleRate: 16_000)
        router.submit(4, samples: Self.samples(token: 4, count: 6), sampleRate: 16_000)

        await gate.release(1)
        await gate.release(3)

        var iterator = appended.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 2)
        #expect(await iterator.next() == 3)
        #expect(await iterator.next() == 4)
        // One reset per closed window — no utterance state bleeds across windows.
        #expect(segmenter.resetCount == 2)
    }

    @Test("should flush a silence-only pending tail to ASR on finish")
    func silenceOnlyPendingTailFailsOpenOnFinish() async {
        let gate = WindowGate()
        let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
        // The segmenter never reports an edge, so no window is ever cut.
        let segmenter = ScriptedSegmenter([:])
        let router = UtteranceWindowRouter<Int>(
            segmenter: segmenter,
            classify: Self.gatedClassify(gate: gate, decisions: [1: .discard(reason: .pilotVoice)]),
            append: { appendContinuation.yield($0) }
        )

        router.submit(1, samples: Self.samples(token: 1, count: 4), sampleRate: 16_000)
        router.submit(2, samples: Self.samples(token: 2, count: 4), sampleRate: 16_000)
        for _ in 0..<50 { await Task.yield() }
        #expect(await gate.snapshot() == [])

        router.finish()
        appendContinuation.finish()

        var appendedTokens: [Int] = []
        for await token in appended { appendedTokens.append(token) }
        // Uncertain tail flushed in submit order, never classified for discard.
        #expect(appendedTokens == [1, 2])
        #expect(await gate.snapshot() == [])
    }

    @Test("should fail open and append the whole window when classification throws")
    func classifierErrorFailsOpenAppendingWholeWindow() async {
        let gate = WindowGate()
        let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
        let segmenter = ScriptedSegmenter([1: .accumulate, 2: .cutAfterSilence])
        let router = UtteranceWindowRouter<Int>(
            segmenter: segmenter,
            classify: Self.gatedClassify(gate: gate, decisions: [:], errorTokens: [1]),
            append: { appendContinuation.yield($0) }
        )

        router.submit(1, samples: Self.samples(token: 1, count: 6), sampleRate: 16_000)
        router.submit(2, samples: Self.samples(token: 2, count: 6), sampleRate: 16_000)
        await gate.release(1)

        var iterator = appended.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 2)
    }

    @Test("should apply windows in submit order even when a later window classifies first")
    func windowsAppliedInSubmitOrderWhenLaterClassifiesFirst() async {
        let gate = WindowGate()
        let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
        // Every buffer is its own one-block window (edge on each submit).
        let segmenter = ScriptedSegmenter([
            1: .cutAfterSilence,
            2: .cutAfterSilence,
            3: .cutAfterSilence,
        ])
        let router = UtteranceWindowRouter<Int>(
            segmenter: segmenter,
            classify: Self.gatedClassify(
                gate: gate,
                decisions: [
                    1: .transcribe(reason: .nonPilotVoice),
                    2: .discard(reason: .pilotVoice),
                    3: .transcribe(reason: .nonPilotVoice),
                ]
            ),
            append: { appendContinuation.yield($0) }
        )

        router.submit(1, samples: Self.samples(token: 1, count: 4), sampleRate: 16_000)
        router.submit(2, samples: Self.samples(token: 2, count: 4), sampleRate: 16_000)
        router.submit(3, samples: Self.samples(token: 3, count: 4), sampleRate: 16_000)

        // Release out of submit order: a correct serial router still applies window
        // 1, drops window 2 (pilot), then applies window 3 — in submit order.
        await gate.release(3)
        await gate.release(2)
        await gate.release(1)

        var iterator = appended.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 3)
        #expect(
            await gate.snapshot() == [.start(1), .finish(1), .start(2), .finish(2), .start(3), .finish(3)]
        )
    }

    @Test("should not append buffers submitted after finish")
    func bufferSubmittedAfterFinishIsNeverAppended() async {
        let gate = WindowGate()
        await confirmation("append after finish", expectedCount: 0) { appended in
            let segmenter = ScriptedSegmenter([1: .cutAfterSilence])
            let router = UtteranceWindowRouter<Int>(
                segmenter: segmenter,
                classify: Self.gatedClassify(gate: gate, decisions: [1: .transcribe(reason: .nonPilotVoice)]),
                append: { _ in appended() }
            )

            router.finish()
            router.submit(1, samples: Self.samples(token: 1, count: 4), sampleRate: 16_000)
            await gate.release(1)

            for _ in 0..<100 { await Task.yield() }
        }
    }

    @Test("should fail open an in-flight cut window before a pending tail on finish")
    func finishFailOpensInFlightCutWindowBeforePendingTailOnce() async {
        let gate = WindowGate()
        let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
        let segmenter = ScriptedSegmenter([
            1: .cutAfterSilence,
            2: .accumulate,
        ])
        let router = UtteranceWindowRouter<Int>(
            segmenter: segmenter,
            classify: Self.gatedClassify(gate: gate, decisions: [1: .discard(reason: .pilotVoice)]),
            append: { appendContinuation.yield($0) }
        )

        // Window A is cut and starts classifying. Window B is only a pending tail
        // when finish() fires, so both are unresolved and must fail-open in capture
        // order instead of appending B while dropping A.
        router.submit(1, samples: Self.samples(token: 1, count: 4), sampleRate: 16_000)
        for _ in 0..<50 {
            if await gate.snapshot() == [.start(1)] { break }
            await Task.yield()
        }
        #expect(await gate.snapshot() == [.start(1)])

        router.submit(2, samples: Self.samples(token: 2, count: 4), sampleRate: 16_000)
        router.finish()

        // The classifier eventually resolves to discard, but finish already
        // fail-opened A once; the late result must not remove or duplicate it.
        await gate.release(1)
        for _ in 0..<100 { await Task.yield() }
        appendContinuation.finish()

        var appendedTokens: [Int] = []
        for await token in appended { appendedTokens.append(token) }
        #expect(appendedTokens == [1, 2])
        #expect(await gate.snapshot() == [.start(1), .finish(1)])
    }
}

// Deterministic, Sendable scripted segmenter. Keys its decision on the first
// sample (the buffer token) so the test fully controls where windows are cut,
// with no energy math, no clock, and no randomness. `resetCount` proves the
// router resets utterance state at each cut.
fileprivate final class ScriptedSegmenter: SpeechActivitySegmenter {
    private let decisionForToken: [Int: SegmentationDecision]
    private let resets = Mutex(0)

    init(_ decisionForToken: [Int: SegmentationDecision]) {
        self.decisionForToken = decisionForToken
    }

    func update(block: [Float], sampleRate: Double) -> SegmentationDecision {
        decisionForToken[Int(block.first ?? -1)] ?? .accumulate
    }

    func reset() {
        resets.withLock { $0 += 1 }
    }

    var resetCount: Int { resets.withLock { $0 } }
}

// Block builders for the default segmenter: a "loud" block is full-scale (RMS
// 1.0, above any sane noise floor in (0,1)); a "silent" block is digital zero
// (RMS 0.0). Using these extremes keeps the specs independent of the exact
// energy threshold the engineer picks.
fileprivate func loudBlock(seconds: Double, sampleRate: Double) -> [Float] {
    [Float](repeating: 1.0, count: max(Int(seconds * sampleRate), 1))
}

fileprivate func silentBlock(seconds: Double, sampleRate: Double) -> [Float] {
    [Float](repeating: 0.0, count: max(Int(seconds * sampleRate), 1))
}

// Behavior contract for the default `EnergySilenceSegmenter` — the pure,
// deterministic RMS silence-gap detector the router uses in production. These
// tests pin only formula-agnostic properties (loud > threshold > silent, and the
// injected timing knobs), never an exact energy constant, so the engineer is
// free to tune the noise floor. RED until `EnergySilenceSegmenter` exists.
//
// Pinned API:
//   final class EnergySilenceSegmenter: SpeechActivitySegmenter {
//       init(minSpeechSeconds: Double, minSilenceSeconds: Double, maxWindowSeconds: Double)
//   }
@MainActor
struct EnergySilenceSegmenterTests {
    private static let sampleRate = 16_000.0
    private static let block = 0.1                 // seconds per block
    private static let minSpeech = 0.2
    private static let minSilence = 0.3
    private static let maxWindow = 1.0

    private static func makeSegmenter() -> EnergySilenceSegmenter {
        EnergySilenceSegmenter(
            minSpeechSeconds: minSpeech,
            minSilenceSeconds: minSilence,
            maxWindowSeconds: maxWindow
        )
    }

    private static func decisions(
        _ segmenter: EnergySilenceSegmenter,
        _ blocks: [[Float]]
    ) -> [SegmentationDecision] {
        blocks.map { segmenter.update(block: $0, sampleRate: sampleRate) }
    }

    @Test("should never cut on silence that has no preceding speech")
    func silenceWithoutPrecedingSpeechNeverCuts() {
        let segmenter = Self.makeSegmenter()
        // Six silent blocks (0.6 s) — well past minSilence, but no utterance ever
        // opened, so there is nothing to close.
        let blocks = Array(repeating: silentBlock(seconds: Self.block, sampleRate: Self.sampleRate), count: 6)
        let result = Self.decisions(segmenter, blocks)
        #expect(result.allSatisfy { $0 == .accumulate })
    }

    @Test("should cut after a trailing silence edge once speech has occurred")
    func trailingSilenceAfterSpeechCutsWindow() {
        let segmenter = Self.makeSegmenter()
        let loud = loudBlock(seconds: Self.block, sampleRate: Self.sampleRate)
        let silent = silentBlock(seconds: Self.block, sampleRate: Self.sampleRate)
        // 0.3 s speech (>= minSpeech) then up to 0.5 s silence.
        let blocks = Array(repeating: loud, count: 3) + Array(repeating: silent, count: 5)

        var firstCutIndex: Int?
        var firstCutDecision: SegmentationDecision = .accumulate
        for (index, samples) in blocks.enumerated() {
            let decision = segmenter.update(block: samples, sampleRate: Self.sampleRate)
            if decision != .accumulate {
                firstCutIndex = index
                firstCutDecision = decision
                break
            }
        }

        #expect(firstCutDecision == .cutAfterSilence)
        let cutIndex = try! #require(firstCutIndex)
        // Cut lands once trailing silence reaches minSilence — tolerant of a
        // >= vs > boundary (within one block).
        let silentBlocksAtCut = cutIndex - 3 + 1
        #expect(silentBlocksAtCut >= 3)
        #expect(silentBlocksAtCut <= 4)
    }

    @Test("should cut continuous speech at the max-window cap")
    func continuousSpeechCutsAtMaxWindowCap() {
        let segmenter = Self.makeSegmenter()
        let loud = loudBlock(seconds: Self.block, sampleRate: Self.sampleRate)
        let blocks = Array(repeating: loud, count: 12)   // 1.2 s, past the 1.0 s cap

        var firstCutIndex: Int?
        var firstCutDecision: SegmentationDecision = .accumulate
        for (index, samples) in blocks.enumerated() {
            let decision = segmenter.update(block: samples, sampleRate: Self.sampleRate)
            if decision != .accumulate {
                firstCutIndex = index
                firstCutDecision = decision
                break
            }
        }

        #expect(firstCutDecision == .cutAtMaxWindow)
        let cutIndex = try! #require(firstCutIndex)
        let secondsAtCut = Double(cutIndex + 1) * Self.block
        // Never larger than the old fixed 1.0 s window (within one block of slack).
        #expect(secondsAtCut >= Self.maxWindow - 1e-9)
        #expect(secondsAtCut <= Self.maxWindow + Self.block + 1e-9)
    }

    @Test("should not cut after silence when speech was shorter than minSpeechSeconds")
    func briefSpeechBelowMinSpeechDoesNotCutAfterSilence() {
        let segmenter = Self.makeSegmenter()
        let loud = loudBlock(seconds: Self.block, sampleRate: Self.sampleRate)
        let silent = silentBlock(seconds: Self.block, sampleRate: Self.sampleRate)
        // 0.1 s speech (< minSpeech) then long silence up to the cap.
        let blocks = [loud] + Array(repeating: silent, count: 11)

        var firstCutDecision: SegmentationDecision = .accumulate
        for samples in blocks {
            let decision = segmenter.update(block: samples, sampleRate: Self.sampleRate)
            if decision != .accumulate {
                firstCutDecision = decision
                break
            }
        }

        // Too-short speech is not an utterance; only the cap may close the window.
        #expect(firstCutDecision == .cutAtMaxWindow)
    }

    @Test("should produce identical decisions for an identical input sequence")
    func deterministicForSameInputSequence() {
        let loud = loudBlock(seconds: Self.block, sampleRate: Self.sampleRate)
        let silent = silentBlock(seconds: Self.block, sampleRate: Self.sampleRate)
        let blocks = Array(repeating: loud, count: 3) + Array(repeating: silent, count: 5)

        let first = Self.decisions(Self.makeSegmenter(), blocks)
        let second = Self.decisions(Self.makeSegmenter(), blocks)
        #expect(first == second)
    }

    @Test("should clear accumulated speech and silence on reset")
    func resetClearsAccumulatedState() {
        let segmenter = Self.makeSegmenter()
        let loud = loudBlock(seconds: Self.block, sampleRate: Self.sampleRate)
        let silent = silentBlock(seconds: Self.block, sampleRate: Self.sampleRate)

        // Drive a full speech→silence cut, then reset.
        for samples in Array(repeating: loud, count: 3) + Array(repeating: silent, count: 4) {
            _ = segmenter.update(block: samples, sampleRate: Self.sampleRate)
        }
        segmenter.reset()

        // After reset there is no preceding speech, so a lone silent block cannot
        // close a window.
        #expect(segmenter.update(block: silent, sampleRate: Self.sampleRate) == .accumulate)
    }
}
