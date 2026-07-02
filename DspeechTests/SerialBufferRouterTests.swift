import Foundation
import Testing

@testable import Dspeech

// Behavior contract for the serial pre-ASR routing seam.
//
// Captured audio buffers must be classified off the main actor, but the
// append/discard decision into Apple Speech must be applied in FIFO order with
// respect to capture order — a later buffer may never overtake an earlier one
// that is still classifying. Classifier errors fail open (append) without
// disturbing order, and once the request is ended no further buffers append.
//
// The seam is exercised through injected closures rather than a real
// `SFSpeechAudioBufferRecognitionRequest`.
//
// Contract:
//   1. Buffers are processed serially in submit order; `append` is invoked only
//      for `.transcribe` decisions, in submit order, regardless of how long any
//      individual classification takes.
//   2. A `.discard` decision drops its buffer (no `append`) but a following
//      buffer still may not be applied until the earlier buffer's decision has
//      resolved.
//   3. A thrown classifier error fails open: that buffer is appended and the
//      order of following buffers is preserved.
//   4. After `finish()`, buffers submitted later are never appended.
@MainActor
struct SerialBufferRouterTests {

  // Deterministic test double: classification suspends until the test releases
  // each token, and records an ordered event log so serialization is provable
  // without sleeps or wall-clock timing. Tokens are encoded in `samples[0]`.
  actor SerialGate {
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

  nonisolated private static func token(from samples: [Float]) -> Int {
    Int(samples.first ?? -1)
  }

  nonisolated private static func samples(for token: Int) -> [Float] { [Float(token)] }

  nonisolated private static func gatedClassify(
    gate: SerialGate,
    decisions: [Int: PreTranscriptionRoutingDecision],
    errorTokens: Set<Int> = []
  ) -> @Sendable ([Float], Double) async throws -> PreTranscriptionRoutingDecision {
    { samples, _ in
      let token = SerialBufferRouterTests.token(from: samples)
      await gate.begin(token)
      await gate.end(token)
      if errorTokens.contains(token) {
        throw LocalSpeakerIdentifierError.captureFailed(reason: "scripted-\(token)")
      }
      return decisions[token] ?? .transcribe(reason: .nonPilotVoice)
    }
  }

  @Test("should append buffer 1 before buffer 2 when buffer 2 classifies first")
  func appendsInSubmitOrderWhenLaterBufferClassifiesFirst() async {
    let gate = SerialGate()
    let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
    let router = SerialBufferRouter<Int>(
      classify: Self.gatedClassify(
        gate: gate,
        decisions: [
          1: .transcribe(reason: .nonPilotVoice),
          2: .transcribe(reason: .nonPilotVoice),
        ]
      ),
      append: { appendContinuation.yield($0) }
    )

    router.submit(1, samples: Self.samples(for: 1), sampleRate: 16_000)
    router.submit(2, samples: Self.samples(for: 2), sampleRate: 16_000)

    // Release the later buffer first: a correct serial router still applies
    // buffer 1 before buffer 2; an eager-concurrent one would append 2 first.
    await gate.release(2)
    await gate.release(1)

    var iterator = appended.makeAsyncIterator()
    #expect(await iterator.next() == 1)
    #expect(await iterator.next() == 2)
    #expect(
      await gate.snapshot() == [.start(1), .finish(1), .start(2), .finish(2)]
    )
  }

  @Test("should not append buffer 2 early when buffer 1 is still classifying and gets discarded")
  func laterBufferWaitsForEarlierDiscardDecision() async {
    let gate = SerialGate()
    let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
    let router = SerialBufferRouter<Int>(
      classify: Self.gatedClassify(
        gate: gate,
        decisions: [
          1: .discard(reason: .pilotVoice),
          2: .transcribe(reason: .nonPilotVoice),
        ]
      ),
      append: { appendContinuation.yield($0) }
    )

    router.submit(1, samples: Self.samples(for: 1), sampleRate: 16_000)
    router.submit(2, samples: Self.samples(for: 2), sampleRate: 16_000)

    // Buffer 2's classification is unblocked first, but it must not overtake
    // buffer 1 — which is still classifying and will be discarded.
    await gate.release(2)
    await gate.release(1)

    var iterator = appended.makeAsyncIterator()
    // Buffer 1 is discarded (never appended); buffer 2 is the only append,
    // and the event log proves it was applied strictly after buffer 1.
    #expect(await iterator.next() == 2)
    #expect(
      await gate.snapshot() == [.start(1), .finish(1), .start(2), .finish(2)]
    )
  }

  @Test("should append the errored buffer and preserve order when classification throws")
  func classifierErrorAppendsBufferAndPreservesOrder() async {
    let gate = SerialGate()
    let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
    let router = SerialBufferRouter<Int>(
      classify: Self.gatedClassify(
        gate: gate,
        decisions: [
          1: .transcribe(reason: .nonPilotVoice),
          3: .transcribe(reason: .nonPilotVoice),
        ],
        errorTokens: [2]
      ),
      append: { appendContinuation.yield($0) }
    )

    router.submit(1, samples: Self.samples(for: 1), sampleRate: 16_000)
    router.submit(2, samples: Self.samples(for: 2), sampleRate: 16_000)
    router.submit(3, samples: Self.samples(for: 3), sampleRate: 16_000)

    await gate.release(1)
    await gate.release(2)
    await gate.release(3)

    var iterator = appended.makeAsyncIterator()
    #expect(await iterator.next() == 1)
    // Buffer 2's classifier threw — it must fail open to ASR, not be dropped.
    #expect(await iterator.next() == 2)
    #expect(await iterator.next() == 3)
  }

  @Test("should never discard a buffer when classification fails open to transcribe")
  func failOpenTranscribeDecisionsNeverDiscard() async {
    let gate = SerialGate()
    let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
    // .classifierUnavailable is what the gate returns for an absent/disabled
    // pack or an unavailable identifier; the serial router must append it.
    let router = SerialBufferRouter<Int>(
      classify: Self.gatedClassify(
        gate: gate,
        decisions: [
          1: .transcribe(reason: .classifierUnavailable),
          2: .transcribe(reason: .classifierUnavailable),
          3: .transcribe(reason: .classifierUnavailable),
        ]
      ),
      append: { appendContinuation.yield($0) }
    )

    router.submit(1, samples: Self.samples(for: 1), sampleRate: 16_000)
    router.submit(2, samples: Self.samples(for: 2), sampleRate: 16_000)
    router.submit(3, samples: Self.samples(for: 3), sampleRate: 16_000)

    await gate.release(1)
    await gate.release(2)
    await gate.release(3)

    var iterator = appended.makeAsyncIterator()
    #expect(await iterator.next() == 1)
    #expect(await iterator.next() == 2)
    #expect(await iterator.next() == 3)
  }

  @Test("should not append buffers submitted after finish")
  func finishPreventsFutureAppends() async {
    let gate = SerialGate()
    await confirmation("append after finish", expectedCount: 0) { appended in
      let router = SerialBufferRouter<Int>(
        classify: Self.gatedClassify(
          gate: gate,
          decisions: [1: .transcribe(reason: .nonPilotVoice)]
        ),
        append: { _ in appended() }
      )

      // Stop/cleanup happens before this buffer is ever submitted.
      router.finish()
      router.submit(1, samples: Self.samples(for: 1), sampleRate: 16_000)
      await gate.release(1)

      // Give a router that ignores finish() every opportunity to run its
      // worker and append on the cooperative pool; a correct router never
      // starts classification for a post-finish buffer.
      for _ in 0..<100 { await Task.yield() }
    }
  }
}
