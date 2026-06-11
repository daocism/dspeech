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

struct PilotVoiceProfile: Identifiable, Equatable, Sendable, Codable {
  enum Slot: Int, Codable, Sendable, CaseIterable {
    case primary = 0
    case secondary = 1
  }

  let id: UUID
  let slot: Slot
  let label: String
  let voicePrint: VoicePrintVector
  let enrolledAt: Date
  let spokenCallSign: CallSign?

  init(
    id: UUID = UUID(),
    slot: Slot,
    label: String,
    voicePrint: VoicePrintVector,
    enrolledAt: Date = .now,
    spokenCallSign: CallSign? = nil
  ) {
    self.id = id
    self.slot = slot
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
  case pilot(slot: PilotVoiceProfile.Slot, score: Float)
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
