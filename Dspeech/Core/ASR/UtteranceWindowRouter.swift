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
      classify: classify,
      // why: one classification decides the whole window — every buffer in
      // the chunk is appended together, in capture order, or none is.
      append: { chunk in for buffer in chunk { append(buffer) } }
    )
  }

  func submit(_ buffer: Buffer, samples: [Float], sampleRate: Double) {
    guard !finished else { return }
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
    let tailSamples = pending.flatMap(\.samples)
    let tailSampleRate = pending.last?.sampleRate ?? 0
    pending.removeAll()
    if !tailBuffers.isEmpty {
      inner.submit(tailBuffers, samples: tailSamples, sampleRate: tailSampleRate)
    }
    inner.finish()
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
