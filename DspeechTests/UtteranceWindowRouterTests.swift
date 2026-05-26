import Foundation
import Testing
@testable import Dspeech

// Behavior contract for the utterance-aware pre-ASR routing seam.
//
// `SerialBufferRouter` classifies and routes one capture buffer at a time, so a
// single buffer that a classifier flags as pilot is discarded in isolation —
// which can silently remove ATC audio when the classifier is wrong about a tiny
// fragment. `UtteranceWindowRouter<Buffer>` wraps the serial seam and only lets a
// discard happen for a *coherent decision window*: it accumulates buffers until
// the window reaches `minimumChunkSamples`, classifies the whole concatenated
// window once, and applies that single decision to every buffer in the chunk. A
// window below threshold is never classified for discard; on `finish()` the
// pending sub-threshold tail is flushed (fail open) and no buffer is ever
// appended after the recognition request is ended.
//
// These tests drive a seam that does not yet exist in production; they are RED
// (compile failure: "cannot find 'UtteranceWindowRouter' in scope") until the
// engineer lands it. The seam is exercised through injected closures rather than
// a real `SFSpeechAudioBufferRecognitionRequest`:
//
//   @MainActor
//   final class UtteranceWindowRouter<Buffer> {
//       init(
//           minimumChunkSamples: Int,
//           classify: @escaping @Sendable ([Float], Double) async throws -> PreTranscriptionRoutingDecision,
//           append: @escaping (Buffer) -> Void
//       )
//       func submit(_ buffer: Buffer, samples: [Float], sampleRate: Double)
//       func finish()
//   }
//
// Contract the engineer must satisfy:
//   1. A sub-threshold window is never classified and never discarded; its
//      buffers are flushed (appended) on finish.
//   2. A coherent window that classifies `.discard` drops every buffer in the
//      chunk as a unit.
//   3. A window that classifies `.transcribe` (any reason), or whose classifier
//      throws, appends every buffer in the chunk as a unit, in submit order.
//   4. Chunks are applied in submit order; a later chunk may never overtake an
//      earlier one whose decision has not yet resolved.
//   5. `finish()` flushes the pending uncertain tail to `append`, and no buffer
//      submitted after `finish()` — nor any chunk still classifying when
//      `finish()` is called — is ever appended.
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

    @Test("should not classify or discard a sub-threshold window even when it would be pilot")
    func subThresholdWindowIsNeverDiscarded() async {
        let gate = WindowGate()
        let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
        let router = UtteranceWindowRouter<Int>(
            minimumChunkSamples: 10,
            // If the lone short buffer were classified, it would be discarded as
            // pilot. The router must not classify it at all below threshold.
            classify: Self.gatedClassify(gate: gate, decisions: [1: .discard(reason: .pilotVoice)]),
            append: { appendContinuation.yield($0) }
        )

        router.submit(1, samples: Self.samples(token: 1, count: 4), sampleRate: 16_000)

        // No chunk is complete, so nothing is classified or routed yet.
        #expect(await gate.snapshot() == [])

        // finish() flushes the uncertain tail to ASR — the pilot-leaning fragment
        // is transcribed, not silently dropped.
        router.finish()
        appendContinuation.finish()

        var appendedTokens: [Int] = []
        for await token in appended { appendedTokens.append(token) }
        #expect(appendedTokens == [1])
        #expect(await gate.snapshot() == [])
    }

    @Test("should discard every buffer in a coherent pilot window as a unit")
    func coherentPilotWindowIsDiscardedAsUnit() async {
        let gate = WindowGate()
        await confirmation("no buffer appended", expectedCount: 0) { appended in
            let router = UtteranceWindowRouter<Int>(
                minimumChunkSamples: 10,
                classify: Self.gatedClassify(gate: gate, decisions: [1: .discard(reason: .pilotVoice)]),
                append: { _ in appended() }
            )

            // Two buffers of 6 samples each = 12 ≥ 10 → one coherent chunk whose
            // first sample (token 1) drives the single classification.
            router.submit(1, samples: Self.samples(token: 1, count: 6), sampleRate: 16_000)
            router.submit(2, samples: Self.samples(token: 0, count: 6), sampleRate: 16_000)

            await gate.release(1)
            for _ in 0..<50 { await Task.yield() }
            #expect(await gate.snapshot() == [.start(1), .finish(1)])
        }
    }

    @Test("should append every buffer in a transcribe window as a unit, in submit order")
    func transcribeWindowAppendsAllBuffersInOrder() async {
        let gate = WindowGate()
        let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
        let router = UtteranceWindowRouter<Int>(
            minimumChunkSamples: 10,
            classify: Self.gatedClassify(gate: gate, decisions: [1: .transcribe(reason: .mixedOrLowConfidence)]),
            append: { appendContinuation.yield($0) }
        )

        router.submit(1, samples: Self.samples(token: 1, count: 6), sampleRate: 16_000)
        router.submit(2, samples: Self.samples(token: 0, count: 6), sampleRate: 16_000)

        await gate.release(1)

        var iterator = appended.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 2)
    }

    @Test("should fail open and append the whole window when classification throws")
    func classifierErrorAppendsWindowAsUnit() async {
        let gate = WindowGate()
        let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
        let router = UtteranceWindowRouter<Int>(
            minimumChunkSamples: 10,
            classify: Self.gatedClassify(gate: gate, decisions: [:], errorTokens: [1]),
            append: { appendContinuation.yield($0) }
        )

        router.submit(1, samples: Self.samples(token: 1, count: 6), sampleRate: 16_000)
        router.submit(2, samples: Self.samples(token: 0, count: 6), sampleRate: 16_000)

        await gate.release(1)

        var iterator = appended.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 2)
    }

    @Test("should apply chunks in submit order even when a later chunk classifies first")
    func chunksAppliedInSubmitOrder() async {
        let gate = WindowGate()
        let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
        // minimumChunkSamples == per-buffer count → every buffer is its own chunk.
        let router = UtteranceWindowRouter<Int>(
            minimumChunkSamples: 4,
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

        // Release out of submit order: a correct serial router still applies chunk
        // 1, then drops chunk 2 (pilot), then applies chunk 3 — in submit order.
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

    @Test("should flush the pending tail in order on finish")
    func finishFlushesPendingTailInOrder() async {
        let gate = WindowGate()
        let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
        let router = UtteranceWindowRouter<Int>(
            minimumChunkSamples: 10,
            classify: Self.gatedClassify(gate: gate, decisions: [:]),
            append: { appendContinuation.yield($0) }
        )

        // Two short buffers totalling 6 samples — below the 10-sample threshold,
        // so they remain pending and uncertain until finish flushes them.
        router.submit(1, samples: Self.samples(token: 1, count: 3), sampleRate: 16_000)
        router.submit(2, samples: Self.samples(token: 2, count: 3), sampleRate: 16_000)

        router.finish()
        appendContinuation.finish()

        var appendedTokens: [Int] = []
        for await token in appended { appendedTokens.append(token) }
        #expect(appendedTokens == [1, 2])
        // The tail was flushed without ever being classified.
        #expect(await gate.snapshot() == [])
    }

    @Test("should not append buffers submitted after finish")
    func finishPreventsFutureAppends() async {
        let gate = WindowGate()
        await confirmation("append after finish", expectedCount: 0) { appended in
            let router = UtteranceWindowRouter<Int>(
                minimumChunkSamples: 1,
                classify: Self.gatedClassify(gate: gate, decisions: [1: .transcribe(reason: .nonPilotVoice)]),
                append: { _ in appended() }
            )

            router.finish()
            router.submit(1, samples: Self.samples(token: 1, count: 4), sampleRate: 16_000)
            await gate.release(1)

            for _ in 0..<100 { await Task.yield() }
        }
    }

    @Test("should not append a chunk still classifying when finish is called")
    func inFlightChunkDoesNotAppendAfterFinish() async {
        let gate = WindowGate()
        await confirmation("append after finish", expectedCount: 0) { appended in
            let router = UtteranceWindowRouter<Int>(
                minimumChunkSamples: 4,
                classify: Self.gatedClassify(gate: gate, decisions: [1: .transcribe(reason: .nonPilotVoice)]),
                append: { _ in appended() }
            )

            // Chunk is complete and classification starts, but the result has not
            // resolved when finish() ends the request.
            router.submit(1, samples: Self.samples(token: 1, count: 4), sampleRate: 16_000)
            for _ in 0..<10 { await Task.yield() }
            router.finish()

            // The in-flight classification now resolves; it must not append into
            // the ended recognition request.
            await gate.release(1)
            for _ in 0..<100 { await Task.yield() }
        }
    }
}
