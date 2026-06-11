import Foundation

@MainActor
final class UtteranceWindowRouter<Buffer> {
  private struct Pending {
    let buffer: Buffer
    let samples: [Float]
    let sampleRate: Double
  }

  private let segmenter: SpeechActivitySegmenter
  private let inner: SerialBufferRouter<[Buffer]>

  private var pending: [Pending] = []
  private var finished = false

  init(
    segmenter: SpeechActivitySegmenter,
    classify: @escaping @Sendable ([Float], Double) async throws -> PreTranscriptionRoutingDecision,
    append: @escaping (Buffer) -> Void
  ) {
    self.segmenter = segmenter
    self.inner = SerialBufferRouter<[Buffer]>(
      classify: { samples, sampleRate in
        guard !samples.isEmpty, sampleRate > 0 else {
          return .transcribe(reason: .classifierUnavailable)
        }
        return try await classify(samples, sampleRate)
      },
      // why: one classification decides the whole window — every buffer in
      // the chunk is appended together, in capture order, or none is.
      append: { chunk in for buffer in chunk { append(buffer) } }
    )
  }

  func submit(_ buffer: Buffer, samples: [Float], sampleRate: Double) {
    guard !finished else { return }
    guard !samples.isEmpty, sampleRate > 0 else {
      flushPendingFailOpen()
      inner.submit([buffer], samples: [], sampleRate: 0)
      return
    }
    pending.append(Pending(buffer: buffer, samples: samples, sampleRate: sampleRate))
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
    let tailBuffers = pending.map(\.buffer)
    pending.removeAll()
    if !tailBuffers.isEmpty {
      inner.submit(tailBuffers, samples: [], sampleRate: 0)
    }
    inner.finish()
  }

  private func flushPendingFailOpen() {
    guard !pending.isEmpty else { return }
    let buffers = pending.map(\.buffer)
    pending.removeAll()
    segmenter.reset()
    inner.submit(buffers, samples: [], sampleRate: 0)
  }

  private func cutChunk() {
    let buffers = pending.map(\.buffer)
    let samples = pending.flatMap(\.samples)
    let sampleRate = pending.last?.sampleRate ?? 0
    pending.removeAll()
    // why: reset per cut so utterance state (speech/silence accumulators) does
    // not bleed into the next window's boundary decision.
    segmenter.reset()
    inner.submit(buffers, samples: samples, sampleRate: sampleRate)
  }
}
