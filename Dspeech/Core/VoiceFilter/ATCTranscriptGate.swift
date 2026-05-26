import Foundation

struct ATCTranscriptGateConfig: Equatable, Sendable, Codable {
    var continuationWindowSeconds: TimeInterval
    var readbackMaxWords: Int

    static let `default` = ATCTranscriptGateConfig(
        continuationWindowSeconds: 8,
        readbackMaxWords: 16
    )
}

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
        timestamp: Date
    ) -> ATCRelevanceDecision {
        switch speaker {
        case .insufficientSpeech:
            return .suppress(reason: .insufficientSpeech)
        case .pilot:
            return .suppress(reason: .pilotReadback)
        case .nonPilot, .mixed:
            break
        }

        guard let callSign = configuredCallSign else {
            return .display(reason: .noCallSignConfigured)
        }

        if callSign.matches(in: text) {
            lastCallSignHitAt = timestamp
            return .display(reason: .callSignMatch)
        }

        if let detector = otherCallSignDetector, detector(text) {
            return .suppress(reason: .addressedToOther)
        }

        if let lastHit = lastCallSignHitAt,
           timestamp.timeIntervalSince(lastHit) <= config.continuationWindowSeconds {
            return .display(reason: .continuationOfRecentHit)
        }

        return .suppress(reason: .nonRelevant)
    }
}
