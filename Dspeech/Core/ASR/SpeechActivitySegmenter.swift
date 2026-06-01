import Foundation
import Synchronization

protocol SpeechActivitySegmenter: Sendable {
  func update(block: [Float], sampleRate: Double) -> SegmentationDecision
  func reset()
}

enum SegmentationDecision: Equatable, Sendable {
  case accumulate
  case cutAfterSilence
  case cutAtMaxWindow
}

// Deterministic RMS silence-gap detector: the pure default backing the router's
// cut decision. A window closes on a trailing-silence utterance edge once enough
// speech has been seen, or on a conservative max-window cap so a continuous-speech
// region can never grow unbounded. No clock, no randomness, no I/O — a pure
// function of the (blocks, sampleRate, config) it is fed. State is Mutex-guarded
// so the type is honestly Sendable for the segmenter seam.
final class EnergySilenceSegmenter: SpeechActivitySegmenter {
  private struct State {
    var speechSeconds = 0.0
    var trailingSilenceSeconds = 0.0
    var windowSeconds = 0.0
  }

  private let minSpeechSeconds: Double
  private let minSilenceSeconds: Double
  private let maxWindowSeconds: Double
  private let energyThreshold: Float
  private let state = Mutex(State())

  init(
    minSpeechSeconds: Double,
    minSilenceSeconds: Double,
    maxWindowSeconds: Double,
    // why: a low RMS noise floor for normalized PCM; conservative because a
    // lower floor counts marginal blocks as speech, biasing toward keeping ATC
    // audio rather than treating it as a silence gap.
    energyThreshold: Float = 0.0125
  ) {
    self.minSpeechSeconds = max(minSpeechSeconds, 0)
    self.minSilenceSeconds = max(minSilenceSeconds, 0)
    self.maxWindowSeconds = max(maxWindowSeconds, 0)
    self.energyThreshold = energyThreshold
  }

  func update(block: [Float], sampleRate: Double) -> SegmentationDecision {
    guard sampleRate > 0, !block.isEmpty else { return .accumulate }
    let blockSeconds = Double(block.count) / sampleRate
    let isSpeech = Self.rootMeanSquare(block) > energyThreshold
    return state.withLock { state in
      state.windowSeconds += blockSeconds
      if isSpeech {
        state.speechSeconds += blockSeconds
        state.trailingSilenceSeconds = 0
      } else {
        state.trailingSilenceSeconds += blockSeconds
      }
      // why: silence only closes a window once a real utterance opened, so a
      // long lead-in of room tone can't trigger a spurious empty cut.
      if state.speechSeconds >= minSpeechSeconds,
        state.trailingSilenceSeconds >= minSilenceSeconds
      {
        return .cutAfterSilence
      }
      if state.windowSeconds >= maxWindowSeconds {
        return .cutAtMaxWindow
      }
      return .accumulate
    }
  }

  func reset() {
    state.withLock { $0 = State() }
  }

  private static func rootMeanSquare(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sumSquares: Float = 0
    for sample in samples { sumSquares += sample * sample }
    return (sumSquares / Float(samples.count)).squareRoot()
  }
}
