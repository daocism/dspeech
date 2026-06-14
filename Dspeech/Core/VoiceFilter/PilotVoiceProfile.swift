import Foundation

enum VoicePrintVectorError: Error, Equatable, Sendable {
  case nonFiniteValue(index: Int)
  case nonFiniteQuality
}

struct VoicePrintVector: Equatable, Sendable, Codable {
  private enum CodingKeys: String, CodingKey {
    case values
    case quality
  }

  let values: [Float]
  let quality: Float

  var dimension: Int { values.count }

  init(values: [Float], quality: Float) {
    self.values = values
    self.quality = quality
  }

  init(validatingValues values: [Float], quality: Float) throws {
    for (index, value) in values.enumerated() where !value.isFinite {
      throw VoicePrintVectorError.nonFiniteValue(index: index)
    }
    guard quality.isFinite else {
      throw VoicePrintVectorError.nonFiniteQuality
    }
    self.values = values
    self.quality = quality
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let values = try container.decode([Float].self, forKey: .values)
    let quality = try container.decode(Float.self, forKey: .quality)
    try self.init(validatingValues: values, quality: quality)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(values, forKey: .values)
    try container.encode(quality, forKey: .quality)
  }
}

// why: a variable-length crew roster, not a fixed 2-slot pair — the cockpit may have any number of
// people on headsets and the pilot adds/removes them at will (2026-06-14 request). Each enrolled
// voice is its own profile keyed by `id`; `label` is its display name. Decoding tolerates pre-roster
// JSON that still carries a `slot` key (Codable ignores unknown keys), so no migration is needed.
struct PilotVoiceProfile: Identifiable, Equatable, Sendable, Codable {
  let id: UUID
  let label: String
  let voicePrint: VoicePrintVector
  let enrolledAt: Date
  let spokenCallSign: CallSign?

  init(
    id: UUID = UUID(),
    label: String,
    voicePrint: VoicePrintVector,
    enrolledAt: Date = .now,
    spokenCallSign: CallSign? = nil
  ) {
    self.id = id
    self.label = label
    self.voicePrint = voicePrint
    self.enrolledAt = enrolledAt
    self.spokenCallSign = spokenCallSign
  }
}

enum PilotVoiceEnrollmentState: Equatable, Sendable {
  case empty
  case capturing(elapsedSeconds: TimeInterval)
  case enrolled(profile: PilotVoiceProfile)
  case insufficientSpeech
  case failed(reason: String)
  case unavailable(reason: String)
}

enum SpeakerMatchDecision: Equatable, Sendable {
  // why: which specific crew member matched is not surfaced anywhere — the filter only needs
  // "this is one of our enrolled own-side voices". Carrying just the score keeps the decision
  // independent of the (now variable-length) roster and removes dead identity payload.
  case pilot(score: Float)
  case nonPilot(bestPilotScore: Float)
  case mixed(bestPilotScore: Float)
  case insufficientSpeech
}

enum PreTranscriptionRoutingDecision: Equatable, Sendable {
  enum Reason: Equatable, Sendable {
    case filterDisabled
    case noPilotProfile
    case pilotVoice
    case nonPilotVoice
    case mixedOrLowConfidence
    case insufficientSpeech
    case classifierUnavailable
  }

  case transcribe(reason: Reason)
  case discard(reason: Reason)
}

enum ATCVoiceIndicator: Equatable, Sendable {
  case filterOff
  case pilotSuppressed
  case dispatcherAddressedOwnCallSign
  case dispatcherContinuation
  case urgencyBroadcast
  case probableDispatcher
  case mixedSpeakerCandidate
  case otherTrafficSuppressed
  case noiseOrTooShortSuppressed
}

enum ATCRelevanceDecision: Equatable, Sendable {
  enum Reason: Equatable, Sendable {
    case noCallSignConfigured
    case filterDisabled
    case urgencyBroadcast
    case callSignMatch
    case continuationOfRecentHit
    case addressedToOther
    case pilotReadback
    case nonRelevant
    case insufficientSpeech
  }

  case display(reason: Reason)
  case suppress(reason: Reason)
  case holdContinuation(reason: Reason)
}
