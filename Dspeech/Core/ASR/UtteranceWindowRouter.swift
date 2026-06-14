import Foundation

@MainActor
final class UtteranceWindowRouter<Buffer> {
  private struct Pending {
    let buffer: Buffer
    let samples: [Float]
    let sampleRate: Double
    let generation: Int
  }

  private let segmenter: SpeechActivitySegmenter
  private let inner: SerialBufferRouter<[(Buffer, Int)]>

  private var pending: [Pending] = []
  private var finished = false

  init(
    segmenter: SpeechActivitySegmenter,
    classify: @escaping @Sendable ([Float], Double) async throws -> PreTranscriptionRoutingDecision,
    // why: the recognition generation captured when each buffer was submitted is carried to the
    // append sink. Classification runs off-actor and can resolve AFTER the recognition request was
    // recycled at an utterance boundary; the engine sink no-ops a stale append so utterance-N audio
    // can't bleed into the next card's request N+1 (adversarial-audit HIGH, 2026-06-14).
    append: @escaping (Buffer, Int) -> Void
  ) {
    self.segmenter = segmenter
    self.inner = SerialBufferRouter<[(Buffer, Int)]>(
      classify: { samples, sampleRate in
        guard !samples.isEmpty, sampleRate > 0 else {
          return .transcribe(reason: .classifierUnavailable)
        }
        return try await classify(samples, sampleRate)
      },
      // why: one classification decides the whole window — every buffer in
      // the chunk is appended together, in capture order, or none is.
      append: { chunk in for (buffer, generation) in chunk { append(buffer, generation) } }
    )
  }

  // why: generation defaults to 0 only for the test seam; the live engine always passes its current
  // taskGeneration so the append sink can reject buffers from a recycled request.
  func submit(_ buffer: Buffer, samples: [Float], sampleRate: Double, generation: Int = 0) {
    guard !finished else { return }
    guard !samples.isEmpty, sampleRate > 0 else {
      flushPendingFailOpen()
      inner.submit([(buffer, generation)], samples: [], sampleRate: 0)
      return
    }
    pending.append(
      Pending(buffer: buffer, samples: samples, sampleRate: sampleRate, generation: generation))
    // why: the segmenter decides the window boundary from speech/silence shape,
    // not a fixed sample count — so a window straddling a pilot→dispatcher PTT
    // transition is cut at the silence gap instead of discarding both as one.
    switch segmenter.update(block: samples, sampleRate: sampleRate) {
    case .accumulate:
      break
    case .cutAfterSilence, .cutAtMaxWindow:
      cutChunk()
    }
  }

  func finish() {
    finished = true
    // why: the pending tail never reached a decision window, so it is uncertain.
    // Enqueue it through the serial router before finalizing so an earlier cut
    // window still classifying fail-opens ahead of it instead of being dropped.
    let tail = pending.map { ($0.buffer, $0.generation) }
    pending.removeAll()
    if !tail.isEmpty {
      inner.submit(tail, samples: [], sampleRate: 0)
    }
    inner.finish()
  }

  private func flushPendingFailOpen() {
    guard !pending.isEmpty else { return }
    let buffers = pending.map { ($0.buffer, $0.generation) }
    pending.removeAll()
    segmenter.reset()
    inner.submit(buffers, samples: [], sampleRate: 0)
  }

  private func cutChunk() {
    let buffers = pending.map { ($0.buffer, $0.generation) }
    let samples = pending.flatMap(\.samples)
    let sampleRate = pending.last?.sampleRate ?? 0
    pending.removeAll()
    // why: reset per cut so utterance state (speech/silence accumulators) does
    // not bleed into the next window's boundary decision.
    segmenter.reset()
    inner.submit(buffers, samples: samples, sampleRate: sampleRate)
  }
}
