import Foundation

enum TransmissionDisplayReason: String, Equatable, Sendable, Codable {
  case callSignMatch
  case urgencyBroadcast
  case nonPilotVoice
  case noAnchorConfigured
  case insufficientEvidence
  case continuationOfRecentCall
}

enum TransmissionFilterReason: String, Equatable, Sendable, Codable {
  case pilotVoice
  case addressedToOther
  case nonRelevant
}

enum TransmissionClassification: Equatable, Sendable, Codable {
  case displayed(TransmissionDisplayReason)
  case filtered(TransmissionFilterReason)

  var isDisplayed: Bool {
    if case .displayed = self { return true }
    return false
  }

  enum CodingKeys: String, CodingKey {
    case kind
    case reason
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    switch kind {
    case "displayed":
      self = .displayed(try container.decode(TransmissionDisplayReason.self, forKey: .reason))
    case "filtered":
      self = .filtered(try container.decode(TransmissionFilterReason.self, forKey: .reason))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "Unknown transmission classification kind '\(kind)'"
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .displayed(let reason):
      try container.encode("displayed", forKey: .kind)
      try container.encode(reason, forKey: .reason)
    case .filtered(let reason):
      try container.encode("filtered", forKey: .kind)
      try container.encode(reason, forKey: .reason)
    }
  }
}

struct Transmission: Identifiable, Equatable, Sendable, Codable {
  let id: UUID
  let startedAt: Date
  let endedAt: Date
  let text: String
  let segments: [TranscriptSegment]
  let classification: TransmissionClassification
  let localeIdentifier: String

  init(
    id: UUID = UUID(),
    startedAt: Date,
    endedAt: Date,
    text: String,
    segments: [TranscriptSegment],
    classification: TransmissionClassification,
    localeIdentifier: String
  ) {
    self.id = id
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.text = text
    self.segments = segments
    self.classification = classification
    self.localeIdentifier = localeIdentifier
  }
}

enum TransmissionUpdate: Equatable, Sendable {
  case opened(Transmission)
  case updated(Transmission)
  case closed(Transmission)

  var transmission: Transmission {
    switch self {
    case .opened(let transmission), .updated(let transmission), .closed(let transmission):
      return transmission
    }
  }
}
