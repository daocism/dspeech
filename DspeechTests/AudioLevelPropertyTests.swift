@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import Dspeech

// Property-based tests for AudioLevel — the pure RMS→bar mapping. A deterministic seeded PRNG
// (reused SeededGenerator) drives every generator so a failure repeats from its seed. Every branch
// of normalized(rms:floorDecibels:) is exercised: the (rms <= 0) and (non-finite) guard arms, the
// db <= floor zero arm, the db >= 0 top-clamp arm, and the interior linear arm — plus the
// statically reachable rms(of:) buffer reduction (empty/zero guard and the sqrt-mean path).
//
// Domain note (conservative): the floor generator yields ONLY strictly-negative dB floors, which is
// the real usage (default -50; quieter = more negative). A non-negative floor makes -floorDecibels
// non-positive and breaks both the [0,1] range and the floor semantics, so those inputs are OUT of
// the provable contract and deliberately not asserted.
struct AudioLevelPropertyTests {

  // MARK: - Generators (component-specific, file-private)

  // Strictly-negative dB floor, the only regime where normalized's contract holds.
  private static func randomFloor(using rng: inout SeededGenerator) -> Float {
    Float(Int.random(in: -800...(-1), using: &rng)) / 10  // -80.0 ... -0.1 dB
  }

  // Positive finite RMS spanning the full sub-floor / interior / over-unity range.
  private static func randomPositiveRMS(using rng: inout SeededGenerator) -> Float {
    let exponent = Float(Int.random(in: -60...10, using: &rng)) / 10  // 1e-6 ... ~3.16
    return pow(10, exponent)
  }

  private static let nonFiniteRMS: [Float] = [.nan, .infinity, -.infinity]

  private static let nonPositiveRMS: [Float] = [
    0, -0.0, -0.001, -0.5, -1, -1000, -Float.greatestFiniteMagnitude,
  ]

  private static func monoBuffer(samples: [Float]) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let pointer = buffer.floatChannelData![0]
    for (frame, sample) in samples.enumerated() { pointer[frame] = sample }
    return buffer
  }

  private static func randomSamples(using rng: inout SeededGenerator) -> [Float] {
    let count = Int.random(in: 1...512, using: &rng)
    return (0..<count).map { _ in Float(Int.random(in: -1000...1000, using: &rng)) / 1000 }
  }

  // MARK: - Range invariant: result ALWAYS in [0, 1]

  // Every reachable input — positive, zero, negative, non-finite — maps into the closed [0,1] bar.
  @Test func resultAlwaysInUnitInterval() {
    var rng = SeededGenerator(seed: 0xA1D0_0001)
    var exercised = 0
    for _ in 0..<300 {
      let floor = Self.randomFloor(using: &rng)
      let rmsCandidates: [Float] =
        [Self.randomPositiveRMS(using: &rng)]
        + [Self.nonFiniteRMS.randomElement(using: &rng)!]
        + [Self.nonPositiveRMS.randomElement(using: &rng)!]
      for rms in rmsCandidates {
        let level = AudioLevel.normalized(rms: rms, floorDecibels: floor)
        #expect(level >= 0, "below 0 for rms=\(rms) floor=\(floor): \(level)")
        #expect(level <= 1, "above 1 for rms=\(rms) floor=\(floor): \(level)")
        exercised += 1
      }
    }
    #expect(exercised >= 800, "too few cases reached the assertion: \(exercised)")
  }

  // MARK: - Guard arm: non-positive rms → exactly 0

  // rms <= 0 (including -0.0 and large negatives) hits the `rms > 0` guard and returns exactly 0,
  // independent of the floor.
  @Test func nonPositiveRMSIsExactlyZero() {
    var rng = SeededGenerator(seed: 0xA1D0_0002)
    var exercised = 0
    for _ in 0..<300 {
      let floor = Self.randomFloor(using: &rng)
      let rms = Self.nonPositiveRMS.randomElement(using: &rng)!
      #expect(
        AudioLevel.normalized(rms: rms, floorDecibels: floor) == 0,
        "non-positive rms=\(rms) floor=\(floor) was not zero")
      exercised += 1
    }
    #expect(exercised >= 280, "too few cases reached the assertion: \(exercised)")
  }

  // MARK: - Guard arm: non-finite rms → exactly 0

  // NaN / +Inf / -Inf hit the `rms.isFinite` guard and return exactly 0, independent of the floor.
  @Test func nonFiniteRMSIsExactlyZero() {
    var rng = SeededGenerator(seed: 0xA1D0_0003)
    var exercised = 0
    for _ in 0..<300 {
      let floor = Self.randomFloor(using: &rng)
      let rms = Self.nonFiniteRMS.randomElement(using: &rng)!
      #expect(
        AudioLevel.normalized(rms: rms, floorDecibels: floor) == 0,
        "non-finite rms=\(rms) floor=\(floor) was not zero")
      exercised += 1
    }
    #expect(exercised >= 280, "too few cases reached the assertion: \(exercised)")
  }

  // MARK: - Floor arm: rms whose dB is at/below the floor → exactly 0

  // Any positive rms with 20*log10(rms) <= floor hits the `db <= floorDecibels` arm → exactly 0.
  // Constructed by mapping a target dB at or below the floor back to a linear rms.
  @Test func atOrBelowFloorIsExactlyZero() {
    var rng = SeededGenerator(seed: 0xA1D0_0004)
    var exercised = 0
    for _ in 0..<300 {
      let floor = Self.randomFloor(using: &rng)
      // target dB in [floor - 40, floor]; pow keeps rms strictly positive and finite.
      let targetDb = floor - Float(Int.random(in: 0...400, using: &rng)) / 10
      let rms = pow(10, targetDb / 20)
      guard rms > 0, rms.isFinite else { continue }
      #expect(
        AudioLevel.normalized(rms: rms, floorDecibels: floor) == 0,
        "rms=\(rms) (≈\(targetDb) dB) at/below floor=\(floor) was not zero")
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // MARK: - Top-clamp arm: rms >= 1.0 (dB >= 0) → exactly 1

  // Any rms >= 1.0 has dB >= 0 and hits the `db >= 0` arm → exactly 1, regardless of the floor.
  @Test func atOrAboveFullScaleIsExactlyOne() {
    var rng = SeededGenerator(seed: 0xA1D0_0005)
    var exercised = 0
    for _ in 0..<300 {
      let floor = Self.randomFloor(using: &rng)
      // rms in [1.0, ~1000]; all map to db >= 0.
      let rms = pow(10, Float(Int.random(in: 0...300, using: &rng)) / 100)
      guard rms.isFinite else { continue }
      #expect(
        AudioLevel.normalized(rms: rms, floorDecibels: floor) == 1,
        "full-scale rms=\(rms) floor=\(floor) was not one")
      exercised += 1
    }
    #expect(exercised >= 280, "too few cases reached the assertion: \(exercised)")
  }

  // MARK: - Interior arm: floor < dB < 0 → strictly inside (0, 1)

  // rms with floor < 20*log10(rms) < 0 hits the linear arm and lands strictly inside (0,1).
  @Test func interiorMapsStrictlyInsideUnitInterval() {
    var rng = SeededGenerator(seed: 0xA1D0_0006)
    var exercised = 0
    for _ in 0..<300 {
      let floor = Self.randomFloor(using: &rng)
      // target dB strictly between floor and 0 (floor is < 0, so this interval is non-empty).
      let span = -floor  // > 0
      // margin in from the (floor, 0) edges so the pow/log10 round-trip can't drift db out of the
      // interior arm — the interior branch is then hit on every iteration (no silent skip).
      let fraction = Float(Int.random(in: 50...950, using: &rng)) / 1000
      let targetDb = floor + span * fraction  // strictly inside (floor, 0) with margin
      let rms = pow(10, targetDb / 20)
      let level = AudioLevel.normalized(rms: rms, floorDecibels: floor)
      #expect(level > 0, "interior rms=\(rms) floor=\(floor) collapsed to 0: \(level)")
      #expect(level < 1, "interior rms=\(rms) floor=\(floor) saturated to 1: \(level)")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // MARK: - Monotonic non-decreasing in rms

  // Holding the floor fixed, a larger positive rms never produces a smaller bar level.
  @Test func monotonicNonDecreasingInRMS() {
    var rng = SeededGenerator(seed: 0xA1D0_0007)
    var exercised = 0
    for _ in 0..<300 {
      let floor = Self.randomFloor(using: &rng)
      let a = Self.randomPositiveRMS(using: &rng)
      let b = Self.randomPositiveRMS(using: &rng)
      let lo = min(a, b)
      let hi = max(a, b)
      let levelLo = AudioLevel.normalized(rms: lo, floorDecibels: floor)
      let levelHi = AudioLevel.normalized(rms: hi, floorDecibels: floor)
      #expect(
        levelHi >= levelLo,
        "non-monotonic: rms \(lo)→\(levelLo) vs \(hi)→\(levelHi) at floor=\(floor)")
      exercised += 1
    }
    #expect(exercised >= 280, "too few cases reached the assertion: \(exercised)")
  }

  // MARK: - Determinism

  // normalized is pure: identical inputs (incl. guard/non-finite arms) yield identical output.
  @Test func normalizedIsDeterministic() {
    var rng = SeededGenerator(seed: 0xA1D0_0008)
    var exercised = 0
    for _ in 0..<300 {
      let floor = Self.randomFloor(using: &rng)
      let rms: Float
      switch Int.random(in: 0...2, using: &rng) {
      case 0: rms = Self.randomPositiveRMS(using: &rng)
      case 1: rms = Self.nonFiniteRMS.randomElement(using: &rng)!
      default: rms = Self.nonPositiveRMS.randomElement(using: &rng)!
      }
      let first = AudioLevel.normalized(rms: rms, floorDecibels: floor)
      let second = AudioLevel.normalized(rms: rms, floorDecibels: floor)
      #expect(first == second, "non-deterministic for rms=\(rms) floor=\(floor)")
      exercised += 1
    }
    #expect(exercised >= 280, "too few cases reached the assertion: \(exercised)")
  }

  // MARK: - rms(of:) — statically reachable buffer reduction

  // RMS of a non-empty mono buffer is non-negative, finite, and bounded by the peak |sample| —
  // a provable bound for the sqrt(mean of squares) of values whose magnitudes are all <= peak.
  @Test func rmsIsNonNegativeFiniteAndBoundedByPeak() {
    var rng = SeededGenerator(seed: 0xA1D0_0009)
    var exercised = 0
    for _ in 0..<300 {
      let samples = Self.randomSamples(using: &rng)
      let buffer = Self.monoBuffer(samples: samples)
      let rms = AVAudioEngineInputLevelMeter.rms(of: buffer)
      let peak = samples.map { abs($0) }.max() ?? 0
      #expect(rms >= 0, "negative rms \(rms)")
      #expect(rms.isFinite, "non-finite rms \(rms)")
      #expect(rms <= peak + 1e-5, "rms \(rms) exceeded peak \(peak)")
      exercised += 1
    }
    #expect(exercised >= 280, "too few cases reached the assertion: \(exercised)")
  }

  // The empty/zero guard arm: an all-silence buffer reduces to exactly 0, and normalizes to 0.
  @Test func rmsOfSilenceIsZeroAndNormalizesToZero() {
    var rng = SeededGenerator(seed: 0xA1D0_000A)
    var exercised = 0
    for _ in 0..<300 {
      let count = Int.random(in: 1...512, using: &rng)
      let buffer = Self.monoBuffer(samples: [Float](repeating: 0, count: count))
      let rms = AVAudioEngineInputLevelMeter.rms(of: buffer)
      #expect(rms == 0, "silence rms not zero: \(rms)")
      #expect(AudioLevel.normalized(rms: rms) == 0, "silence did not normalize to 0")
      exercised += 1
    }
    #expect(exercised >= 280, "too few cases reached the assertion: \(exercised)")
  }
}
