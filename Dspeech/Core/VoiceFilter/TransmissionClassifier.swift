import Foundation

struct TransmissionClassifierConfig: Equatable, Sendable {
  var continuationWindowSeconds: TimeInterval

  static let `default` = TransmissionClassifierConfig(continuationWindowSeconds: 8)
}

struct TransmissionClassifier: Sendable {
  var config: TransmissionClassifierConfig
  var configuredCallSign: CallSign?
  var localeIdentifier: String?
  var voicePackActive: Bool
  var otherCallSignDetector: (@Sendable (String) -> Bool)?
  private var lastAnchorEndedAt: Date?

  init(
    config: TransmissionClassifierConfig = .default,
    configuredCallSign: CallSign?,
    localeIdentifier: String?,
    voicePackActive: Bool,
    otherCallSignDetector: (@Sendable (String) -> Bool)? = nil
  ) {
    self.config = config
    self.configuredCallSign = configuredCallSign
    self.localeIdentifier = localeIdentifier
    self.voicePackActive = voicePackActive
    self.otherCallSignDetector = otherCallSignDetector
    self.lastAnchorEndedAt = nil
  }

  mutating func classify(
    text: String,
    speakers: [SpeakerMatchDecision],
    endedAt: Date
  ) -> TransmissionClassification {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .displayed(.insufficientEvidence) }

    if ATCTranscriptGate.containsUrgencyBroadcast(in: text) {
      lastAnchorEndedAt = endedAt
      return .displayed(.urgencyBroadcast)
    }

    if let configuredCallSign,
      configuredCallSign.matches(in: text, localeIdentifier: localeIdentifier)
        || configuredCallSign.matchesAbbreviated(in: text, localeIdentifier: localeIdentifier)
    {
      lastAnchorEndedAt = endedAt
      return .displayed(.callSignMatch)
    }

    if voicePackActive, let voiceClassification = Self.voiceClassification(speakers) {
      return voiceClassification
    }

    if configuredCallSign == nil, !voicePackActive {
      return .displayed(.noAnchorConfigured)
    }

    if let otherCallSignDetector, otherCallSignDetector(text) {
      return .filtered(.addressedToOther)
    }

    if let lastAnchorEndedAt,
      endedAt.timeIntervalSince(lastAnchorEndedAt) <= config.continuationWindowSeconds
    {
      return .displayed(.continuationOfRecentCall)
    }

    return .filtered(.nonRelevant)
  }

  private static func voiceClassification(
    _ speakers: [SpeakerMatchDecision]
  ) -> TransmissionClassification? {
    let relevant = speakers.filter {
      if case .insufficientSpeech = $0 { return false }
      return true
    }
    guard !relevant.isEmpty else { return nil }

    let pilotCount = relevant.filter {
      if case .pilot = $0 { return true }
      return false
    }.count
    let nonPilotCount = relevant.filter {
      if case .nonPilot = $0 { return true }
      return false
    }.count
    if pilotCount * 2 > relevant.count {
      return .filtered(.pilotVoice)
    }
    if nonPilotCount * 2 > relevant.count {
      return .displayed(.nonPilotVoice)
    }
    return nil
  }
}
