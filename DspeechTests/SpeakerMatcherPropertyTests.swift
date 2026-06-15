import Foundation
import Testing

@testable import Dspeech

// Property-based tests for the pure-logic SpeakerMatcher core (cosineSimilarity + match). A
// deterministic seeded PRNG (SeededGenerator from PropertyTestSupport) drives every generator so a
// failing case reproduces exactly from its seed (testing rule: no real randomness). Each property
// pins a CONSERVATIVE, provably-true invariant and the suite as a whole covers EVERY branch of the
// SUT: the three early-return guards and four decision bands of match(), plus the empty /
// mismatched / zero / normal paths of cosineSimilarity. Loops carry an `exercised` counter so a
// branch that is silently never reached fails loudly instead of passing vacuously.

// MARK: - Component generators (file-scope, private — do NOT touch PropertyTestSupport)

// A non-zero embedding of `dimension` floats in roughly [-1, 1]. Guaranteed non-zero so cosine's
// denom > 0 path is taken (one coordinate is forced away from zero).
private func nonZeroVector(dimension: Int, using rng: inout SeededGenerator) -> [Float] {
  var values: [Float] = []
  for _ in 0..<dimension {
    values.append(Float(Int.random(in: -1000...1000, using: &rng)) / 1000)
  }
  let forced = Int.random(in: 0..<dimension, using: &rng)
  // why: avoid an all-zero vector (cosine denom == 0) by forcing one nonzero coordinate.
  values[forced] = Bool.random(using: &rng) ? 0.5 : -0.5
  return values
}

// A unit 2-D vector whose cosine against the x-axis [1, 0] is exactly `score` (clamped to [-1, 1]).
// Mirrors the construction the example tests use to land scores in a target band.
private func unitVector(cosineAgainstXAxis score: Float) -> [Float] {
  let clamped = min(Float(1), max(Float(-1), score))
  return [clamped, max(Float(0), 1 - clamped * clamped).squareRoot()]
}

private func vector(_ values: [Float], quality: Float) -> VoicePrintVector {
  VoicePrintVector(values: values, quality: quality)
}

private func profile(_ values: [Float]) -> PilotVoiceProfile {
  PilotVoiceProfile(
    label: "Crew",
    voicePrint: VoicePrintVector(values: values, quality: 0.9),
    enrolledAt: Date(timeIntervalSince1970: 0)
  )
}

// A config with a valid band ordering: 0 < mixedLower < pilotThreshold < 1, minQuality in (0, 1).
// Bounds are kept strictly inside (0, 1) and separated so the three bands are all non-empty.
private func randomConfig(using rng: inout SeededGenerator) -> SpeakerMatchConfig {
  let minQuality = Float(Int.random(in: 50...700, using: &rng)) / 1000
  let mixedLower = Float(Int.random(in: 50...600, using: &rng)) / 1000
  let pilotThreshold = mixedLower + Float(Int.random(in: 50...350, using: &rng)) / 1000
  return SpeakerMatchConfig(
    minQuality: minQuality,
    pilotMatchThreshold: min(Float(0.99), pilotThreshold),
    mixedSpeakerLowerBound: mixedLower
  )
}

struct SpeakerMatcherPropertyTests {

  // MARK: - cosineSimilarity

  // Self-similarity of any non-zero vector is ~1 — the normal denom > 0 path returning a value at
  // the upper bound of [-1, 1].
  @Test func cosineSelfSimilarityIsOneForNonZeroVectors() {
    var rng = SeededGenerator(seed: 0x5_0001)
    var exercised = 0
    for _ in 0..<300 {
      let dim = Int.random(in: 1...32, using: &rng)
      let v = nonZeroVector(dimension: dim, using: &rng)
      let cos = SpeakerMatcher.cosineSimilarity(v, v)
      #expect(abs(cos - 1) < 1e-3, "self-similarity \(cos) not ~1 for \(v)")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // Cosine is symmetric: cos(a, b) == cos(b, a) for any equal-length non-zero vectors.
  @Test func cosineIsSymmetric() {
    var rng = SeededGenerator(seed: 0x5_0002)
    var exercised = 0
    for _ in 0..<300 {
      let dim = Int.random(in: 1...32, using: &rng)
      let a = nonZeroVector(dimension: dim, using: &rng)
      let b = nonZeroVector(dimension: dim, using: &rng)
      let ab = SpeakerMatcher.cosineSimilarity(a, b)
      let ba = SpeakerMatcher.cosineSimilarity(b, a)
      #expect(ab == ba, "asymmetric cosine \(ab) vs \(ba) for \(a) / \(b)")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // Cosine is bounded in [-1, 1] for any equal-length non-zero vectors (normal denom > 0 path).
  @Test func cosineIsBoundedInMinusOneToOne() {
    var rng = SeededGenerator(seed: 0x5_0003)
    var exercised = 0
    for _ in 0..<300 {
      let dim = Int.random(in: 1...32, using: &rng)
      let a = nonZeroVector(dimension: dim, using: &rng)
      let b = nonZeroVector(dimension: dim, using: &rng)
      let cos = SpeakerMatcher.cosineSimilarity(a, b)
      #expect(cos >= -1 - 1e-3 && cos <= 1 + 1e-3, "cosine \(cos) outside [-1,1]")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // Mismatched-length OR empty inputs return exactly 0 (the first guard) — negative path.
  @Test func cosineMismatchedOrEmptyReturnsZero() {
    var rng = SeededGenerator(seed: 0x5_0004)
    var exercised = 0
    for _ in 0..<300 {
      let dim = Int.random(in: 1...16, using: &rng)
      let a = nonZeroVector(dimension: dim, using: &rng)
      // a strictly different length (dim+1) — never equal, so the count guard fires.
      let b = nonZeroVector(dimension: dim + 1, using: &rng)
      #expect(SpeakerMatcher.cosineSimilarity(a, b) == 0, "mismatched length must be 0")
      #expect(SpeakerMatcher.cosineSimilarity([], []) == 0, "empty/empty must be 0")
      #expect(SpeakerMatcher.cosineSimilarity([], a) == 0, "empty vs nonempty must be 0")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // An equal-length all-zero vector drives denom == 0 → the second guard returns exactly 0.
  @Test func cosineZeroVectorReturnsZero() {
    var rng = SeededGenerator(seed: 0x5_0005)
    var exercised = 0
    for _ in 0..<300 {
      let dim = Int.random(in: 1...16, using: &rng)
      let zeros = [Float](repeating: 0, count: dim)
      let other = nonZeroVector(dimension: dim, using: &rng)
      #expect(SpeakerMatcher.cosineSimilarity(zeros, zeros) == 0, "zero/zero must be 0")
      #expect(SpeakerMatcher.cosineSimilarity(zeros, other) == 0, "zero/other must be 0")
      #expect(SpeakerMatcher.cosineSimilarity(other, zeros) == 0, "other/zero must be 0")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // MARK: - match() early-return guards

  // Quality strictly below minQuality → .insufficientSpeech, regardless of profiles (first guard,
  // quality sub-branch). Candidate values are non-empty so ONLY the quality condition can fire.
  @Test func qualityBelowFloorIsInsufficientSpeech() {
    var rng = SeededGenerator(seed: 0x5_0010)
    var exercised = 0
    for _ in 0..<300 {
      let config = randomConfig(using: &rng)
      let low = max(Float(0), config.minQuality - Float(Int.random(in: 1...50, using: &rng)) / 1000)
      // why: only assert when the perturbation actually lands strictly below the floor.
      guard low < config.minQuality else { continue }
      let cand = vector([1, 0], quality: low)
      let decision = SpeakerMatcher.match(
        candidate: cand, profiles: [profile([1, 0])], config: config)
      #expect(
        decision == .insufficientSpeech,
        "quality \(low) < \(config.minQuality) must be insufficient")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // Empty candidate values → .insufficientSpeech even when quality clears the floor (first guard,
  // empty-values sub-branch).
  @Test func emptyCandidateValuesIsInsufficientSpeech() {
    var rng = SeededGenerator(seed: 0x5_0011)
    var exercised = 0
    for _ in 0..<300 {
      let config = randomConfig(using: &rng)
      let q = min(Float(1), config.minQuality + Float(Int.random(in: 0...300, using: &rng)) / 1000)
      let cand = vector([], quality: q)
      let decision = SpeakerMatcher.match(
        candidate: cand, profiles: [profile([1, 0])], config: config)
      #expect(decision == .insufficientSpeech, "empty values must be insufficient")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // No profiles (and a quality-clearing, non-empty candidate) → .nonPilot(bestPilotScore: 0)
  // (second guard). Score payload is exactly 0.
  @Test func noProfilesIsNonPilotWithZeroScore() {
    var rng = SeededGenerator(seed: 0x5_0012)
    var exercised = 0
    for _ in 0..<300 {
      let config = randomConfig(using: &rng)
      let q = min(Float(1), config.minQuality + Float(Int.random(in: 0...300, using: &rng)) / 1000)
      let dim = Int.random(in: 1...16, using: &rng)
      let cand = vector(nonZeroVector(dimension: dim, using: &rng), quality: q)
      let decision = SpeakerMatcher.match(candidate: cand, profiles: [], config: config)
      #expect(decision == .nonPilot(bestPilotScore: 0), "no profiles must be nonPilot score 0")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // Every profile has a dimension different from the candidate → all skipped via the loop's
  // continue guard → scores empty → .nonPilot(bestPilotScore: 0) (fourth guard, max() nil).
  @Test func allDimensionMismatchedProfilesAreNonPilotZero() {
    var rng = SeededGenerator(seed: 0x5_0013)
    var exercised = 0
    for _ in 0..<300 {
      let config = randomConfig(using: &rng)
      let q = min(Float(1), config.minQuality + Float(Int.random(in: 0...300, using: &rng)) / 1000)
      let dim = Int.random(in: 1...16, using: &rng)
      let cand = vector(nonZeroVector(dimension: dim, using: &rng), quality: q)
      // every profile is dim+1 long — none matches the candidate dimension.
      let count = Int.random(in: 1...4, using: &rng)
      var profiles: [PilotVoiceProfile] = []
      for _ in 0..<count {
        profiles.append(profile(nonZeroVector(dimension: dim + 1, using: &rng)))
      }
      let decision = SpeakerMatcher.match(candidate: cand, profiles: profiles, config: config)
      #expect(
        decision == .nonPilot(bestPilotScore: 0), "all-mismatched must be nonPilot score 0")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // A dimension-mismatched profile mixed in with one valid profile is skipped, not crashed: the
  // decision equals the decision computed from the valid profile alone.
  @Test func dimensionMismatchedProfilesAreIgnoredNotFatal() {
    var rng = SeededGenerator(seed: 0x5_0014)
    var exercised = 0
    for _ in 0..<300 {
      let config = randomConfig(using: &rng)
      let q = min(Float(1), config.minQuality + Float(Int.random(in: 0...300, using: &rng)) / 1000)
      let score = Float(Int.random(in: -990...990, using: &rng)) / 1000
      let cand = vector(unitVector(cosineAgainstXAxis: score), quality: q)
      let valid = profile([1, 0])
      let mismatched = profile([1, 0, 0])  // dim 3 vs candidate dim 2 — skipped
      let withNoise = SpeakerMatcher.match(
        candidate: cand, profiles: [mismatched, valid], config: config)
      let validOnly = SpeakerMatcher.match(candidate: cand, profiles: [valid], config: config)
      #expect(withNoise == validOnly, "mismatched profile changed the decision: \(withNoise)")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // MARK: - match() decision bands

  // Best score >= pilotMatchThreshold → .pilot, and the carried score is >= the threshold (the
  // upper band). Candidate is built to land at or just above the threshold.
  @Test func atOrAbovePilotThresholdIsPilot() {
    var rng = SeededGenerator(seed: 0x5_0020)
    var exercised = 0
    for _ in 0..<300 {
      let config = randomConfig(using: &rng)
      let q = min(Float(1), config.minQuality + Float(Int.random(in: 0...300, using: &rng)) / 1000)
      // a target in [pilotThreshold, 0.999] — includes the exact boundary.
      let span = max(Float(0), Float(0.999) - config.pilotMatchThreshold)
      let frac = Float(Int.random(in: 0...1000, using: &rng)) / 1000
      let target = config.pilotMatchThreshold + frac * span
      let cand = vector(unitVector(cosineAgainstXAxis: target), quality: q)
      let decision = SpeakerMatcher.match(
        candidate: cand, profiles: [profile([1, 0])], config: config)
      if case .pilot(let score) = decision {
        #expect(score >= config.pilotMatchThreshold - 1e-3, "pilot score \(score) below threshold")
      } else {
        Issue.record("expected pilot at/above threshold, got \(decision)")
      }
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // The exact pilotMatchThreshold boundary resolves to .pilot (>= is inclusive on the upper edge).
  @Test func exactPilotThresholdBoundaryIsPilot() {
    var rng = SeededGenerator(seed: 0x5_0021)
    var exercised = 0
    for _ in 0..<300 {
      let config = randomConfig(using: &rng)
      let q = min(Float(1), config.minQuality + Float(Int.random(in: 0...300, using: &rng)) / 1000)
      let cand = vector(
        unitVector(cosineAgainstXAxis: config.pilotMatchThreshold), quality: q)
      let decision = SpeakerMatcher.match(
        candidate: cand, profiles: [profile([1, 0])], config: config)
      if case .pilot = decision {
        // expected: a score exactly at the threshold is own-side crew.
      } else {
        Issue.record(
          "expected pilot at exact threshold \(config.pilotMatchThreshold), got \(decision)")
      }
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // Best score in [mixedSpeakerLowerBound, pilotMatchThreshold) → .mixed, score within that band.
  @Test func betweenBoundsIsMixed() {
    var rng = SeededGenerator(seed: 0x5_0022)
    var exercised = 0
    for _ in 0..<300 {
      let config = randomConfig(using: &rng)
      let q = min(Float(1), config.minQuality + Float(Int.random(in: 0...300, using: &rng)) / 1000)
      let span = config.pilotMatchThreshold - config.mixedSpeakerLowerBound
      // target in [lower, threshold) — exclude the upper edge so it stays mixed.
      let frac = Float(Int.random(in: 0...990, using: &rng)) / 1000
      let target = config.mixedSpeakerLowerBound + frac * span
      guard target < config.pilotMatchThreshold else { continue }
      let cand = vector(unitVector(cosineAgainstXAxis: target), quality: q)
      let decision = SpeakerMatcher.match(
        candidate: cand, profiles: [profile([1, 0])], config: config)
      if case .mixed(let score) = decision {
        #expect(score >= config.mixedSpeakerLowerBound - 1e-3, "mixed score \(score) below lower")
        #expect(score < config.pilotMatchThreshold + 1e-3, "mixed score \(score) above threshold")
      } else {
        Issue.record("expected mixed in band, got \(decision)")
      }
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // The exact mixedSpeakerLowerBound boundary resolves to .mixed (>= is inclusive on the lower
  // edge, and the value is strictly below the pilot threshold by construction of randomConfig).
  @Test func exactMixedLowerBoundBoundaryIsMixed() {
    var rng = SeededGenerator(seed: 0x5_0023)
    var exercised = 0
    for _ in 0..<300 {
      let config = randomConfig(using: &rng)
      let q = min(Float(1), config.minQuality + Float(Int.random(in: 0...300, using: &rng)) / 1000)
      let cand = vector(
        unitVector(cosineAgainstXAxis: config.mixedSpeakerLowerBound), quality: q)
      let decision = SpeakerMatcher.match(
        candidate: cand, profiles: [profile([1, 0])], config: config)
      if case .mixed(let score) = decision {
        #expect(score < config.pilotMatchThreshold + 1e-3, "mixed score \(score) above threshold")
      } else {
        Issue.record("expected mixed at exact lower bound, got \(decision)")
      }
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // Best score strictly below mixedSpeakerLowerBound → .nonPilot, carrying the (non-zero) score
  // (the lowest band; distinct from the no-profiles / all-mismatched zero-score nonPilot).
  @Test func belowMixedLowerBoundIsNonPilot() {
    var rng = SeededGenerator(seed: 0x5_0024)
    var exercised = 0
    for _ in 0..<300 {
      let config = randomConfig(using: &rng)
      let q = min(Float(1), config.minQuality + Float(Int.random(in: 0...300, using: &rng)) / 1000)
      // target strictly below the lower bound (down toward -0.99).
      let lowEnd = config.mixedSpeakerLowerBound - Float(0.005)
      guard lowEnd > -0.99 else { continue }
      let frac = Float(Int.random(in: 0...1000, using: &rng)) / 1000
      let target = -0.99 + frac * (lowEnd - (-0.99))
      guard target < config.mixedSpeakerLowerBound else { continue }
      let cand = vector(unitVector(cosineAgainstXAxis: target), quality: q)
      let decision = SpeakerMatcher.match(
        candidate: cand, profiles: [profile([1, 0])], config: config)
      if case .nonPilot(let score) = decision {
        #expect(score < config.mixedSpeakerLowerBound + 1e-3, "nonPilot score \(score) too high")
      } else {
        Issue.record("expected nonPilot below lower bound, got \(decision)")
      }
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // MARK: - cross-cutting invariants

  // match() is a pure function: identical inputs produce identical decisions across repeated calls.
  @Test func matchIsDeterministic() {
    var rng = SeededGenerator(seed: 0x5_0030)
    var exercised = 0
    for _ in 0..<300 {
      let config = randomConfig(using: &rng)
      let q = Float(Int.random(in: 0...1000, using: &rng)) / 1000
      let dim = Int.random(in: 1...8, using: &rng)
      let cand = vector(nonZeroVector(dimension: dim, using: &rng), quality: q)
      let count = Int.random(in: 0...3, using: &rng)
      var profiles: [PilotVoiceProfile] = []
      for _ in 0..<count {
        profiles.append(profile(nonZeroVector(dimension: dim, using: &rng)))
      }
      let first = SpeakerMatcher.match(candidate: cand, profiles: profiles, config: config)
      let second = SpeakerMatcher.match(candidate: cand, profiles: profiles, config: config)
      #expect(first == second, "non-deterministic match: \(first) vs \(second)")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // Decision band is monotone in the best cosine score: a higher candidate score never produces a
  // STRICTLY LOWER-ranked decision (insufficient < nonPilot < mixed < pilot), with quality fixed
  // above the floor and a single fixed profile so score is the only varying input.
  @Test func decisionRankIsMonotoneInScore() {
    var rng = SeededGenerator(seed: 0x5_0031)
    var exercised = 0
    for _ in 0..<300 {
      let config = randomConfig(using: &rng)
      let q = min(Float(1), config.minQuality + 0.05)
      let a = Float(Int.random(in: -990...990, using: &rng)) / 1000
      let b = Float(Int.random(in: -990...990, using: &rng)) / 1000
      let lo = min(a, b)
      let hi = max(a, b)
      let loDec = SpeakerMatcher.match(
        candidate: vector(unitVector(cosineAgainstXAxis: lo), quality: q),
        profiles: [profile([1, 0])], config: config)
      let hiDec = SpeakerMatcher.match(
        candidate: vector(unitVector(cosineAgainstXAxis: hi), quality: q),
        profiles: [profile([1, 0])], config: config)
      #expect(rank(loDec) <= rank(hiDec), "rank fell as score rose: \(loDec) -> \(hiDec)")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  private func rank(_ decision: SpeakerMatchDecision) -> Int {
    switch decision {
    case .insufficientSpeech: return -1
    case .nonPilot: return 0
    case .mixed: return 1
    case .pilot: return 2
    }
  }
}
