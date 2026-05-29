import Foundation

struct SpeakerMatchConfig: Equatable, Sendable, Codable {
  var minQuality: Float
  var pilotMatchThreshold: Float
  var separationMargin: Float
  var mixedSpeakerLowerBound: Float

  static let `default` = SpeakerMatchConfig(
    minQuality: 0.25,
    pilotMatchThreshold: 0.72,
    separationMargin: 0.05,
    mixedSpeakerLowerBound: 0.62
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
    var scored: [(slot: PilotVoiceProfile.Slot, score: Float)] = []
    for profile in profiles {
      guard profile.voicePrint.values.count == candidate.values.count else { continue }
      let score = cosineSimilarity(candidate.values, profile.voicePrint.values)
      scored.append((profile.slot, score))
    }
    guard !scored.isEmpty else {
      return .nonPilot(bestPilotScore: 0)
    }
    scored.sort { $0.score > $1.score }
    let best = scored[0]
    let secondBest = scored.count > 1 ? scored[1].score : -Float.infinity
    let confidentlySeparated = (best.score - secondBest) >= config.separationMargin
    if best.score >= config.pilotMatchThreshold {
      if scored.count == 1 || confidentlySeparated {
        return .pilot(slot: best.slot, score: best.score)
      }
      return .mixed(bestPilotScore: best.score)
    }
    if best.score >= config.mixedSpeakerLowerBound {
      return .mixed(bestPilotScore: best.score)
    }
    return .nonPilot(bestPilotScore: best.score)
  }
}
