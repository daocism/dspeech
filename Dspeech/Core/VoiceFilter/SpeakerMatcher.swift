import Foundation

struct SpeakerMatchConfig: Equatable, Sendable, Codable {
  var minQuality: Float
  var pilotMatchThreshold: Float
  var mixedSpeakerLowerBound: Float

  // why: calibrated against the REAL FluidAudio WeSpeaker model over the controlled labeled
  // corpus (2026-06-13, `swift run SpeakerEval calibrate tmp/voice-corpus
  // scripts/testdata/voice-corpus.json`). Measured raw cosine (1 - FluidAudio cosineDistance):
  //   SAME-voice  0.820 … 0.969 (mean 0.901)
  //   CROSS-voice 0.095 … 0.599 (mean 0.233)
  // A clean, wide gap (0.60 → 0.82). pilotMatchThreshold 0.72 sits safely ABOVE every observed
  // cross-speaker score (never call another speaker crew) and BELOW every same-speaker score
  // (always catch enrolled crew). A confident match to ANY enrolled profile means own-side crew —
  // the whole roster is own-side, so no second-best separation is needed. minQuality 0.25 correctly
  // rejects noisy received-ATC embeddings (measured quality 0.137–0.204) so they fail open (shown)
  // rather than mis-classify; the operator's own clean read-back clears it.
  static let `default` = SpeakerMatchConfig(
    minQuality: 0.25,
    pilotMatchThreshold: 0.72,
    mixedSpeakerLowerBound: 0.50
  )
}

enum SpeakerMatcher {
  static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0
    var na: Float = 0
    var nb: Float = 0
    for i in 0..<a.count {
      dot += a[i] * b[i]
      na += a[i] * a[i]
      nb += b[i] * b[i]
    }
    let denom = (na.squareRoot()) * (nb.squareRoot())
    guard denom > 0 else { return 0 }
    return dot / denom
  }

  static func match(
    candidate: VoicePrintVector,
    profiles: [PilotVoiceProfile],
    config: SpeakerMatchConfig = .default
  ) -> SpeakerMatchDecision {
    guard candidate.quality >= config.minQuality, !candidate.values.isEmpty else {
      return .insufficientSpeech
    }
    guard !profiles.isEmpty else {
      return .nonPilot(bestPilotScore: 0)
    }
    var scores: [Float] = []
    for profile in profiles {
      guard profile.voicePrint.values.count == candidate.values.count else { continue }
      scores.append(cosineSimilarity(candidate.values, profile.voicePrint.values))
    }
    guard let bestScore = scores.max() else {
      return .nonPilot(bestPilotScore: 0)
    }
    // why: ALL enrolled profiles are own-side crew, so a confident match to ANY of them means
    // "our crew spoke" — there is no need to separate it from the second-best (which is just
    // another crew member). A score above the threshold (calibrated well above every observed
    // cross-speaker score) is enough to suppress as own-side.
    if bestScore >= config.pilotMatchThreshold {
      return .pilot(score: bestScore)
    }
    if bestScore >= config.mixedSpeakerLowerBound {
      return .mixed(bestPilotScore: bestScore)
    }
    return .nonPilot(bestPilotScore: bestScore)
  }
}
