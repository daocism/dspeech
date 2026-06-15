import Foundation

struct ATCTranscriptGateConfig: Equatable, Sendable, Codable {
  var continuationWindowSeconds: TimeInterval
  var readbackMaxWords: Int
  // why: suppress a pilot segment as own read-back ONLY at this confidence or above — above the
  // SpeakerMatcher pilotMatchThreshold (0.72) and at the bottom of the measured same-voice range
  // (0.82). A voice match in the uncertain band [0.72, 0.82) is NOT hidden before the callsign
  // check; it falls through to the relevance test and fails open. So a controller false-accepted as
  // crew is never silently suppressed: a hidden clearance is the one unacceptable failure, while
  // showing an extra crew read-back is mere noise. The synthetic calibration corpus understates the
  // real cross-speaker tail, so this margin is deliberate. See the 2026-06-15 crew-voice audit.
  var pilotSuppressThreshold: Float

  static let `default` = ATCTranscriptGateConfig(
    continuationWindowSeconds: 8,
    readbackMaxWords: 16,
    pilotSuppressThreshold: 0.82
  )
}

// why: the SEGMENT-layer relevance gate — runs per ASR segment (one speaker) and drives
// suppressedSegmentIDs. Voice-first: a pilot is suppressed BEFORE the callsign is checked, so the
// crew never re-reads its own transmissions. This intentionally DIVERGES from the card-layer
// TransmissionClassifier (content-first: own callsign is shown even from a pilot). The asymmetry
// is pinned by VoiceFilterDivergenceTests; flipping either decision order is a product decision.
struct ATCTranscriptGate: Sendable {
  var config: ATCTranscriptGateConfig
  var configuredCallSign: CallSign?
  var lastCallSignHitAt: Date?
  var otherCallSignDetector: (@Sendable (String) -> Bool)?

  init(
    config: ATCTranscriptGateConfig = .default,
    configuredCallSign: CallSign? = nil,
    otherCallSignDetector: (@Sendable (String) -> Bool)? = nil
  ) {
    self.config = config
    self.configuredCallSign = configuredCallSign
    self.lastCallSignHitAt = nil
    self.otherCallSignDetector = otherCallSignDetector
  }

  mutating func evaluate(
    text: String,
    speaker: SpeakerMatchDecision,
    timestamp: Date,
    localeIdentifier: String? = nil
  ) -> ATCRelevanceDecision {
    if Self.containsUrgencyBroadcast(in: text) {
      lastCallSignHitAt = timestamp
      DspeechLog.voiceFilter.debug("atc transcript gate display reason=urgencyBroadcast")
      return .display(reason: .urgencyBroadcast)
    }

    switch speaker {
    case .insufficientSpeech:
      DspeechLog.voiceFilter.debug("atc transcript gate display reason=insufficientSpeech")
      return .display(reason: .insufficientSpeech)
    case .pilot(let score) where score >= config.pilotSuppressThreshold:
      DspeechLog.voiceFilter.debug("atc transcript gate suppress reason=pilotReadback")
      return .suppress(reason: .pilotReadback)
    case .pilot, .nonPilot, .mixed:
      // why: a pilot match below the suppress threshold is not confident enough to hide as own
      // read-back — suppressing it before the callsign check could hide a controller false-accepted
      // as crew (a hidden clearance). Fall through to the relevance check and fail open.
      break
    }

    guard let callSign = configuredCallSign else {
      DspeechLog.voiceFilter.debug("atc transcript gate display reason=noCallSignConfigured")
      return .display(reason: .noCallSignConfigured)
    }

    if callSign.matches(in: text, localeIdentifier: localeIdentifier)
      || callSign.matchesAbbreviated(in: text, localeIdentifier: localeIdentifier)
    {
      lastCallSignHitAt = timestamp
      DspeechLog.voiceFilter.debug("atc transcript gate display reason=callSignMatch")
      return .display(reason: .callSignMatch)
    }

    if let detector = otherCallSignDetector, detector(text) {
      DspeechLog.voiceFilter.debug("atc transcript gate suppress reason=addressedToOther")
      return .suppress(reason: .addressedToOther)
    }

    if let lastHit = lastCallSignHitAt,
      timestamp.timeIntervalSince(lastHit) <= config.continuationWindowSeconds
    {
      // why: callers pass the transcript segment timestamp, not evaluation wall time;
      // refreshing here keeps multi-utterance ATC exchanges visible as finals arrive.
      lastCallSignHitAt = timestamp
      DspeechLog.voiceFilter.debug("atc transcript gate display reason=continuationOfRecentHit")
      return .display(reason: .continuationOfRecentHit)
    }

    DspeechLog.voiceFilter.debug("atc transcript gate suppress reason=nonRelevant")
    return .suppress(reason: .nonRelevant)
  }

  static func containsUrgencyBroadcast(in text: String) -> Bool {
    let folded =
      text
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )
      .uppercased()
    let tokens =
      folded
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }

    for token in tokens {
      if token == "MAYDAY" || token == "PANPAN" || token == "SECURITE" {
        return true
      }
    }

    for index in tokens.indices.dropLast() {
      let next = tokens[tokens.index(after: index)]
      if tokens[index] == "PAN", next == "PAN" {
        return true
      }
      if tokens[index] == "ALL", next == "STATIONS" {
        return true
      }
    }
    return false
  }
}
