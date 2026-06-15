import Foundation
import Testing

@testable import Dspeech

// Property-based tests for the adaptive RMS silence segmenter — the core that birthed the
// "dictaphone" bug (whole flight as one un-segmented line) and the silence-churn bug. Over
// randomized block sequences these pin the two directions that matter: continuous speech ALWAYS
// closes within the max window (never one endless utterance), and the boundary detector NEVER cuts
// on pure silence (never churns the recognition request through an inter-transmission pause).
// Deterministic seeded PRNG — see PropertyTestSupport.
struct SpeechActivitySegmenterPropertyTests {

  // Degenerate input is inert: an empty block or a non-positive sample rate accumulates.
  @Test func emptyOrZeroSampleRateAccumulates() {
    var rng = SeededGenerator(seed: 0x5E60_0001)
    var exercised = 0
    for _ in 0..<200 {
      let segmenter = defaultSegmenter()
      #expect(segmenter.update(block: [], sampleRate: segmenterSampleRate) == .accumulate)
      #expect(
        segmenter.update(
          block: block(seconds: randomBlockSeconds(using: &rng), amplitude: 0.5), sampleRate: 0)
          == .accumulate)
      exercised += 1
    }
    #expect(exercised >= 180, "too few cases reached the assertion: \(exercised)")
  }

  // The boundary detector (requireSpeechForMaxWindow) NEVER cuts on a silence-only window, however
  // long — so a long inter-transmission pause can't churn the live recognition request.
  @Test func boundaryDetectorNeverCutsOnPureSilence() {
    var rng = SeededGenerator(seed: 0x5E60_0002)
    var exercised = 0
    for _ in 0..<300 {
      let segmenter = boundarySegmenter()
      let blocks = Int.random(in: 1...40, using: &rng)
      var allAccumulate = true
      for _ in 0..<blocks {
        let decision = segmenter.update(
          block: block(
            seconds: randomBlockSeconds(using: &rng),
            amplitude: randomSilenceAmplitude(using: &rng)),
          sampleRate: segmenterSampleRate)
        if decision != .accumulate { allAccumulate = false }
      }
      #expect(allAccumulate, "boundary detector cut on a pure-silence window")
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // Continuous speech ALWAYS closes within the max window — the anti-dictaphone guarantee. It can
  // never .accumulate forever; the cut is cutAtMaxWindow (no trailing silence to cutAfterSilence).
  @Test func continuousSpeechAlwaysCutsWithinMaxWindow() {
    var rng = SeededGenerator(seed: 0x5E60_0003)
    var exercised = 0
    for _ in 0..<300 {
      let maxWindow = Double(Int.random(in: 5...20, using: &rng)) / 10
      let segmenter = EnergySilenceSegmenter(
        minSpeechSeconds: 0.25, minSilenceSeconds: 0.40, maxWindowSeconds: maxWindow,
        requireSpeechForMaxWindow: Bool.random(using: &rng))
      var cut: SegmentationDecision?
      var fed = 0.0
      while fed <= maxWindow + 0.5, cut == nil {
        let decision = segmenter.update(
          block: block(seconds: 0.1, amplitude: randomSpeechAmplitude(using: &rng)),
          sampleRate: segmenterSampleRate)
        fed += 0.1
        if decision != .accumulate { cut = decision }
      }
      #expect(cut == .cutAtMaxWindow, "continuous speech did not cut at maxWindow=\(maxWindow)")
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // Speech followed by enough trailing silence (within the max window) closes as cutAfterSilence —
  // the normal utterance boundary.
  @Test func speechThenTrailingSilenceCutsAfterSilence() {
    var rng = SeededGenerator(seed: 0x5E60_0004)
    var exercised = 0
    for _ in 0..<300 {
      let segmenter = EnergySilenceSegmenter(
        minSpeechSeconds: 0.25, minSilenceSeconds: 0.40, maxWindowSeconds: 5.0)
      let speech = randomSpeechAmplitude(using: &rng)
      let silence = randomSilenceAmplitude(using: &rng)
      for _ in 0..<4 {
        _ = segmenter.update(
          block: block(seconds: 0.1, amplitude: speech), sampleRate: segmenterSampleRate)
      }
      var cutAfterSilence = false
      for _ in 0..<10 {
        let decision = segmenter.update(
          block: block(seconds: 0.1, amplitude: silence), sampleRate: segmenterSampleRate)
        if decision == .cutAfterSilence {
          cutAfterSilence = true
          break
        }
        if decision == .cutAtMaxWindow { break }
      }
      #expect(cutAfterSilence, "speech then trailing silence did not cutAfterSilence")
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // The segmenter is deterministic: two fresh instances fed the same block sequence agree at every
  // step (no clock, no randomness, no ambient state).
  @Test func decisionsAreDeterministic() {
    var rng = SeededGenerator(seed: 0x5E60_0005)
    var exercised = 0
    for _ in 0..<200 {
      let blocks = randomBlockSequence(using: &rng)
      let first = defaultSegmenter()
      let second = defaultSegmenter()
      for (seconds, amplitude) in blocks {
        let a = first.update(
          block: block(seconds: seconds, amplitude: amplitude), sampleRate: segmenterSampleRate)
        let b = second.update(
          block: block(seconds: seconds, amplitude: amplitude), sampleRate: segmenterSampleRate)
        #expect(a == b)
      }
      exercised += 1
    }
    #expect(exercised >= 180, "too few cases reached the assertion: \(exercised)")
  }

  // reset() restores fresh behavior: after warmup + reset, a probe sequence matches a fresh
  // segmenter step for step.
  @Test func resetRestoresFreshBehavior() {
    var rng = SeededGenerator(seed: 0x5E60_0006)
    var exercised = 0
    for _ in 0..<200 {
      let segmenter = defaultSegmenter()
      for (seconds, amplitude) in randomBlockSequence(using: &rng) {
        _ = segmenter.update(
          block: block(seconds: seconds, amplitude: amplitude), sampleRate: segmenterSampleRate)
      }
      segmenter.reset()
      let fresh = defaultSegmenter()
      for (seconds, amplitude) in randomBlockSequence(using: &rng) {
        let a = segmenter.update(
          block: block(seconds: seconds, amplitude: amplitude), sampleRate: segmenterSampleRate)
        let b = fresh.update(
          block: block(seconds: seconds, amplitude: amplitude), sampleRate: segmenterSampleRate)
        #expect(a == b)
      }
      exercised += 1
    }
    #expect(exercised >= 180, "too few cases reached the assertion: \(exercised)")
  }

  // The default (router) config flushes a silence-only window at the max window — its latency
  // ceiling must fire even with no speech, unlike the boundary detector. (Reviewer-identified gap.)
  @Test func defaultConfigFlushesPureSilenceAtMaxWindow() {
    var rng = SeededGenerator(seed: 0x5E60_0007)
    var exercised = 0
    for _ in 0..<300 {
      let maxWindow = Double(Int.random(in: 5...15, using: &rng)) / 10
      let segmenter = EnergySilenceSegmenter(
        minSpeechSeconds: 0.25, minSilenceSeconds: 0.40, maxWindowSeconds: maxWindow)
      var cut: SegmentationDecision?
      var fed = 0.0
      while fed <= maxWindow + 0.5, cut == nil {
        let decision = segmenter.update(
          block: block(seconds: 0.1, amplitude: randomSilenceAmplitude(using: &rng)),
          sampleRate: segmenterSampleRate)
        fed += 0.1
        if decision != .accumulate { cut = decision }
      }
      #expect(cut == .cutAtMaxWindow, "default config did not flush silence at max=\(maxWindow)")
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // A sub-minSpeech speech burst (which opens the window, speechSeconds > 0) followed by sustained
  // silence still closes at the max window — the boundary detector must not STICK on .accumulate
  // forever. (Reviewer-identified gap; guards a documented prior regression.)
  @Test func boundaryDetectorSubMinSpeechBurstStillCutsAtMaxWindow() {
    var rng = SeededGenerator(seed: 0x5E60_0008)
    var exercised = 0
    for _ in 0..<300 {
      let maxWindow = Double(Int.random(in: 8...15, using: &rng)) / 10
      let segmenter = EnergySilenceSegmenter(
        minSpeechSeconds: 0.25, minSilenceSeconds: 0.40, maxWindowSeconds: maxWindow,
        requireSpeechForMaxWindow: true)
      // one 0.1s speech block: below minSpeech (0.25) but opens the window (speechSeconds > 0)
      _ = segmenter.update(
        block: block(seconds: 0.1, amplitude: randomSpeechAmplitude(using: &rng)),
        sampleRate: segmenterSampleRate)
      var cut: SegmentationDecision?
      var fed = 0.1
      while fed <= maxWindow + 0.5, cut == nil {
        let decision = segmenter.update(
          block: block(seconds: 0.1, amplitude: randomSilenceAmplitude(using: &rng)),
          sampleRate: segmenterSampleRate)
        fed += 0.1
        if decision != .accumulate { cut = decision }
      }
      #expect(cut == .cutAtMaxWindow, "sub-minSpeech burst stuck (never cut) at max=\(maxWindow)")
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }
}

// MARK: - Segmenter-specific generators

private let segmenterSampleRate = 16000.0

private func defaultSegmenter() -> EnergySilenceSegmenter {
  EnergySilenceSegmenter(minSpeechSeconds: 0.25, minSilenceSeconds: 0.40, maxWindowSeconds: 1.0)
}

private func boundarySegmenter() -> EnergySilenceSegmenter {
  EnergySilenceSegmenter(
    minSpeechSeconds: 0.25, minSilenceSeconds: 0.40, maxWindowSeconds: 1.0,
    requireSpeechForMaxWindow: true)
}

private func block(seconds: Double, amplitude: Float) -> [Float] {
  [Float](repeating: amplitude, count: max(1, Int(seconds * segmenterSampleRate)))
}

// well above the capped speech threshold (noiseFloorCap 0.08 * speechRatio 2 = 0.16).
private func randomSpeechAmplitude(using rng: inout SeededGenerator) -> Float {
  Float(Int.random(in: 30...60, using: &rng)) / 100
}

// below the absolute floor (0.006) so it always reads as silence.
private func randomSilenceAmplitude(using rng: inout SeededGenerator) -> Float {
  Float(Int.random(in: 0...4, using: &rng)) / 1000
}

private func randomBlockSeconds(using rng: inout SeededGenerator) -> Double {
  Double(Int.random(in: 5...50, using: &rng)) / 100
}

private func randomBlockSequence(using rng: inout SeededGenerator) -> [(Double, Float)] {
  let count = Int.random(in: 1...30, using: &rng)
  return (0..<count).map { _ in
    let seconds = randomBlockSeconds(using: &rng)
    let amplitude =
      Bool.random(using: &rng)
      ? randomSpeechAmplitude(using: &rng) : randomSilenceAmplitude(using: &rng)
    return (seconds, amplitude)
  }
}
