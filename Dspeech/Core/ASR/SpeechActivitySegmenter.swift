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
//
// why ADAPTIVE, not a fixed energy threshold: a real iPhone's "silence" between
// transmissions is NOT digital zero — the mic noise floor / AGC sits well above any
// fixed absolute RMS constant, so a fixed threshold reads ambient as speech and NEVER
// closes the window (the 2026-06-13 device report: the whole flight became one
// un-segmented "dictaphone" line). Silence is detected RELATIVE to a floating noise
// floor: the minimum RMS over a recent window. Speech is a block sufficiently louder
// than that floor. The floor is capped so a bootstrap window of pure speech can't
// inflate it above the very speech we must detect.
final class EnergySilenceSegmenter: SpeechActivitySegmenter {
  private struct State {
    var speechSeconds = 0.0
    var trailingSilenceSeconds = 0.0
    var windowSeconds = 0.0
    var recentRMS: [(rms: Float, seconds: Double)] = []
    var recentSecondsTotal = 0.0
  }

  private let minSpeechSeconds: Double
  private let minSilenceSeconds: Double
  private let maxWindowSeconds: Double
  private let noiseWindowSeconds: Double
  private let speechRatio: Float
  private let absoluteFloor: Float
  private let noiseFloorCap: Float
  private let state = Mutex(State())

  init(
    minSpeechSeconds: Double,
    minSilenceSeconds: Double,
    maxWindowSeconds: Double,
    // why: the noise floor is the minimum RMS over this trailing window — long enough to
    // span an inter-transmission gap, short enough to track a changing cabin ambient.
    noiseWindowSeconds: Double = 2.0,
    // why: a block must be this many times the floor to count as speech. Relative, so it
    // holds at any absolute mic level (quiet room or noisy cockpit alike).
    speechRatio: Float = 2.0,
    // why: floor for the speech threshold so true digital silence (floor ~0) still has a
    // non-zero gate and a faint hiss never reads as speech.
    absoluteFloor: Float = 0.006,
    // why: cap the estimated floor so a bootstrap window containing only speech can't push
    // the threshold above the speech itself (which would hide the first utterance).
    noiseFloorCap: Float = 0.08
  ) {
    self.minSpeechSeconds = max(minSpeechSeconds, 0)
    self.minSilenceSeconds = max(minSilenceSeconds, 0)
    self.maxWindowSeconds = max(maxWindowSeconds, 0)
    self.noiseWindowSeconds = max(noiseWindowSeconds, 0.1)
    self.speechRatio = max(speechRatio, 1)
    self.absoluteFloor = max(absoluteFloor, 0)
    self.noiseFloorCap = max(noiseFloorCap, max(absoluteFloor, 0))
  }

  func update(block: [Float], sampleRate: Double) -> SegmentationDecision {
    guard sampleRate > 0, !block.isEmpty else { return .accumulate }
    let blockSeconds = Double(block.count) / sampleRate
    let rms = Self.rootMeanSquare(block)
    return state.withLock { state in
      state.recentRMS.append((rms, blockSeconds))
      state.recentSecondsTotal += blockSeconds
      while state.recentRMS.count > 1,
        state.recentSecondsTotal - state.recentRMS[0].seconds >= noiseWindowSeconds
      {
        state.recentSecondsTotal -= state.recentRMS.removeFirst().seconds
      }
      let noiseFloor = min(state.recentRMS.map(\.rms).min() ?? rms, noiseFloorCap)
      let isSpeech = rms > max(absoluteFloor, noiseFloor * speechRatio)

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
