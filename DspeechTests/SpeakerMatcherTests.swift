import AVFoundation
import CryptoKit
import FluidAudio
import Foundation
import Testing

@testable import Dspeech

struct SpeakerMatcherTests {
  private static func vector(_ values: [Float], quality: Float = 0.9) -> VoicePrintVector {
    VoicePrintVector(values: values, quality: quality)
  }

  private static func profile(
    _ values: [Float],
    label: String = "Crew"
  ) -> PilotVoiceProfile {
    PilotVoiceProfile(
      id: UUID(),
      label: label,
      voicePrint: vector(values),
      enrolledAt: Date(timeIntervalSince1970: 0)
    )
  }

  private static func unitVector(cosineAgainstXAxis score: Float) -> [Float] {
    let clamped = min(Float(1), max(Float(-1), score))
    return [clamped, max(Float(0), 1 - clamped * clamped).squareRoot()]
  }

  @Test func cosineSimilarityIdentical() {
    let a: [Float] = [1, 2, 3, 4]
    #expect(abs(SpeakerMatcher.cosineSimilarity(a, a) - 1.0) < 1e-5)
  }

  @Test func cosineSimilarityOrthogonal() {
    #expect(abs(SpeakerMatcher.cosineSimilarity([1, 0, 0, 0], [0, 1, 0, 0])) < 1e-5)
  }

  @Test func cosineSimilarityOpposite() {
    #expect(SpeakerMatcher.cosineSimilarity([1, 1, 1, 1], [-1, -1, -1, -1]) < -0.99)
  }

  @Test func cosineSimilarityMismatchedLength() {
    #expect(SpeakerMatcher.cosineSimilarity([1, 2], [1, 2, 3]) == 0)
    #expect(SpeakerMatcher.cosineSimilarity([], []) == 0)
  }

  @Test func insufficientSpeechBelowQualityFloor() {
    let cand = Self.vector([1, 0, 0, 0], quality: 0.1)
    let decision = SpeakerMatcher.match(
      candidate: cand,
      profiles: [Self.profile([1, 0, 0, 0])]
    )
    #expect(decision == .insufficientSpeech)
  }

  @Test func emptyVectorIsInsufficient() {
    let cand = VoicePrintVector(values: [], quality: 1.0)
    #expect(SpeakerMatcher.match(candidate: cand, profiles: []) == .insufficientSpeech)
  }

  @Test func nonPilotWhenNoProfiles() {
    let decision = SpeakerMatcher.match(candidate: Self.vector([1, 0, 0, 0]), profiles: [])
    if case .nonPilot(let score) = decision {
      #expect(score == 0)
    } else {
      Issue.record("expected nonPilot, got \(decision)")
    }
  }

  @Test func onePilotAboveThresholdMatches() {
    let cand = Self.vector([0.95, 0.31, 0, 0])
    let profiles = [Self.profile([1, 0.3, 0, 0])]
    let decision = SpeakerMatcher.match(candidate: cand, profiles: profiles)
    if case .pilot(let score) = decision {
      #expect(score > 0.99)
    } else {
      Issue.record("expected pilot, got \(decision)")
    }
  }

  @Test func pilotThresholdBoundaryReturnsPilot() {
    let config = SpeakerMatchConfig.default
    let cand = Self.vector(Self.unitVector(cosineAgainstXAxis: config.pilotMatchThreshold))
    let profiles = [
      Self.profile([1, 0]),
      Self.profile([-1, 0]),
    ]

    let decision = SpeakerMatcher.match(candidate: cand, profiles: profiles, config: config)
    if case .pilot = decision {
      // expected: a score at the threshold is own-side crew
    } else {
      Issue.record("expected pilot at threshold boundary, got \(decision)")
    }
  }

  @Test func onePilotBelowThresholdIsNonPilot() {
    let cand = Self.vector([0.2, 1.0, 0, 0])
    let profiles = [Self.profile([1.0, 0.1, 0, 0])]
    let decision = SpeakerMatcher.match(candidate: cand, profiles: profiles)
    if case .nonPilot(let score) = decision {
      #expect(score < 0.72)
    } else {
      Issue.record("expected nonPilot, got \(decision)")
    }
  }

  @Test func mixedLowerBoundBoundaryReturnsMixedBelowPilotThreshold() {
    let config = SpeakerMatchConfig.default
    let cand = Self.vector(Self.unitVector(cosineAgainstXAxis: config.mixedSpeakerLowerBound))
    let profiles = [Self.profile([1, 0])]

    let decision = SpeakerMatcher.match(candidate: cand, profiles: profiles, config: config)
    if case .mixed(let score) = decision {
      #expect(score < config.pilotMatchThreshold)
    } else {
      Issue.record("expected mixed at lower-bound boundary, got \(decision)")
    }
  }

  @Test func confidentMatchToAnyCrewMemberIsPilot() {
    // why: every enrolled profile is own-side crew, so a confident match to the CLOSEST one means
    // crew — the second-best (another crew member) is irrelevant to the own-vs-ATC decision.
    let cand = Self.vector([0, 1.0, 0.05, 0])
    let profiles = [
      Self.profile([1, 0, 0, 0]),
      Self.profile([0, 1, 0, 0]),
    ]
    let decision = SpeakerMatcher.match(candidate: cand, profiles: profiles)
    if case .pilot(let score) = decision {
      #expect(score > 0.99)
    } else {
      Issue.record("expected pilot, got \(decision)")
    }
  }

  @Test func belowThresholdBestIsMixedCandidate() {
    let cand = Self.vector([0.71, 0.71, 0, 0])
    let profiles = [
      Self.profile([1, 0, 0, 0]),
      Self.profile([0, 1, 0, 0]),
    ]
    let decision = SpeakerMatcher.match(candidate: cand, profiles: profiles)
    if case .mixed(let score) = decision {
      #expect(score > 0.6)
    } else {
      Issue.record("expected mixed ambiguous candidate, got \(decision)")
    }
  }

  @Test func confidentMatchStaysPilotEvenWithASecondCloseProfile() {
    // why: with the separation gate removed, two enrolled crew members whose voice prints are close
    // BOTH resolve to pilot when the best score clears the threshold — there is no own-side member
    // who should be shown just because another own-side member sounds similar.
    let config = SpeakerMatchConfig.default
    let cand = Self.vector([1, 0])
    let primary = Self.profile([1, 0])
    for cosine in [Float(0.99), Float(0.95), Float(0.80)] {
      let secondClose = Self.profile(Self.unitVector(cosineAgainstXAxis: cosine))
      let decision = SpeakerMatcher.match(
        candidate: cand,
        profiles: [primary, secondClose],
        config: config
      )
      if case .pilot = decision {
        // expected
      } else {
        Issue.record("expected pilot with a close second profile (cos=\(cosine)), got \(decision)")
      }
    }
  }

  @Test func dimensionMismatchProfileIsSkipped() {
    let cand = Self.vector([1, 0, 0, 0])
    let wrong = PilotVoiceProfile(
      label: "wrong-dim",
      voicePrint: VoicePrintVector(values: [1, 0], quality: 0.9)
    )
    let decision = SpeakerMatcher.match(candidate: cand, profiles: [wrong])
    #expect(decision == .nonPilot(bestPilotScore: 0))
  }

  @Test
  func shouldPreserveSpeakerMatcherBoundaryInvariantsAcross1000GeneratedCasesWhenClassifyingAudio()
  {
    let generatedCaseCount = 1_000
    var random = DeterministicSpeakerMatcherRandom(seed: 0x5A_EE_C4_2026)

    for _ in 0..<generatedCaseCount {
      let config = random.config()
      let qualityAboveFloor = min(Float(1), config.minQuality + 0.05)
      let primary = Self.profile([1, 0])

      let pilotScore = random.float(
        in: min(Float(0.999), config.pilotMatchThreshold + 0.005)...0.999)
      let pilotDecision = SpeakerMatcher.match(
        candidate: Self.vector(
          Self.unitVector(cosineAgainstXAxis: pilotScore), quality: qualityAboveFloor),
        profiles: [primary],
        config: config
      )
      if case .pilot(let score) = pilotDecision {
        #expect(score >= config.pilotMatchThreshold)
      } else {
        Issue.record("expected generated pilot decision, got \(pilotDecision)")
      }

      let mixedScore = random.float(
        in: config.mixedSpeakerLowerBound...(config.pilotMatchThreshold - 0.005))
      let mixedDecision = SpeakerMatcher.match(
        candidate: Self.vector(
          Self.unitVector(cosineAgainstXAxis: mixedScore), quality: qualityAboveFloor),
        profiles: [primary],
        config: config
      )
      if case .mixed(let score) = mixedDecision {
        #expect(score >= config.mixedSpeakerLowerBound)
        #expect(score < config.pilotMatchThreshold)
      } else {
        Issue.record("expected generated mixed decision, got \(mixedDecision)")
      }

      let nonPilotScore = random.float(in: -0.999...(config.mixedSpeakerLowerBound - 0.005))
      let nonPilotDecision = SpeakerMatcher.match(
        candidate: Self.vector(
          Self.unitVector(cosineAgainstXAxis: nonPilotScore), quality: qualityAboveFloor),
        profiles: [primary],
        config: config
      )
      if case .nonPilot(let score) = nonPilotDecision {
        #expect(score < config.mixedSpeakerLowerBound)
      } else {
        Issue.record("expected generated non-pilot decision, got \(nonPilotDecision)")
      }

      let lowQualityDecision = SpeakerMatcher.match(
        candidate: Self.vector([1, 0], quality: max(Float(0), config.minQuality - 0.005)),
        profiles: [primary],
        config: config
      )
      #expect(lowQualityDecision == .insufficientSpeech)

      // why: with a confident best match, a SECOND crew profile (separated OR close) never changes
      // the own-side decision — the whole roster is own-side. Both must remain pilot.
      for secondCosine in [
        Float(1 - 0.005), config.pilotMatchThreshold, Float(0.30),
      ] {
        let secondProfile = Self.profile(Self.unitVector(cosineAgainstXAxis: secondCosine))
        let multiProfileDecision = SpeakerMatcher.match(
          candidate: Self.vector([1, 0], quality: qualityAboveFloor),
          profiles: [primary, secondProfile],
          config: config
        )
        if case .pilot = multiProfileDecision {
          // expected: best (primary, score 1.0) clears the threshold => own-side crew
        } else {
          Issue.record("expected pilot (cos=\(secondCosine)) got \(multiProfileDecision)")
        }
      }

      let firstScore = random.float(in: -0.999...0.998)
      let secondScore = random.float(in: firstScore...0.999)
      let firstDecision = SpeakerMatcher.match(
        candidate: Self.vector(
          Self.unitVector(cosineAgainstXAxis: firstScore), quality: qualityAboveFloor),
        profiles: [primary],
        config: config
      )
      let secondDecision = SpeakerMatcher.match(
        candidate: Self.vector(
          Self.unitVector(cosineAgainstXAxis: secondScore), quality: qualityAboveFloor),
        profiles: [primary],
        config: config
      )
      #expect(Self.rank(firstDecision) <= Self.rank(secondDecision))
    }

    print("PBT_CASE_COUNT hysteresis=1000")
    #expect(generatedCaseCount == 1_000)
  }

  private static func rank(_ decision: SpeakerMatchDecision) -> Int {
    switch decision {
    case .insufficientSpeech:
      return -1
    case .nonPilot:
      return 0
    case .mixed:
      return 1
    case .pilot:
      return 2
    }
  }
}

struct VoicePrintVectorCodableTests {
  @Test func decodeRejectsNaNEmbeddingValue() throws {
    let json = #"{"values":[0.1,"NaN",0.3],"quality":0.9}"#.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "Infinity",
      negativeInfinity: "-Infinity",
      nan: "NaN"
    )

    do {
      _ = try decoder.decode(VoicePrintVector.self, from: json)
      Issue.record("expected non-finite embedding decode to throw")
    } catch let error as VoicePrintVectorError {
      #expect(error == .nonFiniteValue(index: 1))
    } catch {
      Issue.record("expected VoicePrintVectorError, got \(error)")
    }
  }

  @Test func decodeRejectsInfiniteQuality() throws {
    let json = #"{"values":[0.1,0.2,0.3],"quality":"Infinity"}"#.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "Infinity",
      negativeInfinity: "-Infinity",
      nan: "NaN"
    )

    do {
      _ = try decoder.decode(VoicePrintVector.self, from: json)
      Issue.record("expected non-finite quality decode to throw")
    } catch let error as VoicePrintVectorError {
      #expect(error == .nonFiniteQuality)
    } catch {
      Issue.record("expected VoicePrintVectorError, got \(error)")
    }
  }

  @Test func validatingInitializerRejectsInfiniteEmbeddingValue() throws {
    do {
      _ = try VoicePrintVector(validatingValues: [0.1, .infinity], quality: 0.9)
      Issue.record("expected non-finite embedding init to throw")
    } catch let error as VoicePrintVectorError {
      #expect(error == .nonFiniteValue(index: 1))
    } catch {
      Issue.record("expected VoicePrintVectorError, got \(error)")
    }
  }
}

private struct DeterministicSpeakerMatcherRandom {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func config() -> SpeakerMatchConfig {
    let minQuality = float(in: 0.05...0.70)
    let mixedLower = float(in: 0.05...0.70)
    let pilotThreshold = float(in: (mixedLower + 0.02)...0.99)
    return SpeakerMatchConfig(
      minQuality: minQuality,
      pilotMatchThreshold: pilotThreshold,
      mixedSpeakerLowerBound: mixedLower
    )
  }

  mutating func next() -> UInt64 {
    state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
    return state
  }

  mutating func double() -> Double {
    Double(next() >> 11) / Double(UInt64(1) << 53)
  }

  mutating func float(in range: ClosedRange<Float>) -> Float {
    let unit = Float(double())
    return range.lowerBound + (range.upperBound - range.lowerBound) * unit
  }
}
