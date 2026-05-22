import Foundation

enum VoiceFilterCapability: Equatable, Sendable {
    case ready
    case unavailable(reason: String)
}

struct VoiceFilterDecision: Equatable, Sendable {
    let segmentText: String
    let speaker: SpeakerMatchDecision
    let relevance: ATCRelevanceDecision
    let indicator: ATCVoiceIndicator
    let timestamp: Date
}

@MainActor
final class VoiceFilterPipeline {
    private let identifier: any LocalSpeakerIdentifier
    private let storage: VoiceFilterStorage
    private let matchConfig: SpeakerMatchConfig
    private var gate: ATCTranscriptGate

    private(set) var profiles: [PilotVoiceProfile]
    private(set) var callSign: CallSign?
    private(set) var enabled: Bool

    init(
        identifier: any LocalSpeakerIdentifier,
        storage: VoiceFilterStorage = UserDefaultsVoiceFilterStorage(),
        matchConfig: SpeakerMatchConfig = .default
    ) {
        self.identifier = identifier
        self.storage = storage
        self.matchConfig = matchConfig
        self.profiles = storage.loadProfiles()
        self.callSign = storage.loadCallSign()
        self.enabled = storage.loadEnabled()
        self.gate = ATCTranscriptGate(
            config: storage.loadGateConfig(),
            configuredCallSign: storage.loadCallSign()
        )
    }

    var capability: VoiceFilterCapability {
        switch identifier.availability {
        case .available: return .ready
        case .unavailable(let reason): return .unavailable(reason: reason)
        }
    }

    var enrolledSlots: Set<PilotVoiceProfile.Slot> {
        Set(profiles.map(\.slot))
    }

    func setEnabled(_ flag: Bool) {
        enabled = flag
        storage.saveEnabled(flag)
    }

    func setCallSign(_ raw: String?) {
        if let raw, let parsed = CallSign(raw: raw) {
            callSign = parsed
        } else {
            callSign = nil
        }
        gate.configuredCallSign = callSign
        storage.saveCallSign(callSign)
    }

    func enrollPilot(
        slot: PilotVoiceProfile.Slot,
        label: String,
        samples: [Float],
        sampleRate: Double,
        spokenCallSign rawCallSign: String? = nil
    ) async throws -> PilotVoiceProfile {
        let vector = try await identifier.enroll(samples: samples, sampleRate: sampleRate)
        let spokenCallSign = rawCallSign.flatMap(CallSign.init(raw:))
        let profile = PilotVoiceProfile(
            slot: slot,
            label: label,
            voicePrint: vector,
            spokenCallSign: spokenCallSign
        )
        profiles.removeAll { $0.slot == slot }
        profiles.append(profile)
        storage.saveProfiles(profiles)
        if let spokenCallSign {
            callSign = spokenCallSign
            gate.configuredCallSign = spokenCallSign
            storage.saveCallSign(spokenCallSign)
        }
        return profile
    }

    func removePilot(slot: PilotVoiceProfile.Slot) {
        profiles.removeAll { $0.slot == slot }
        storage.saveProfiles(profiles)
    }

    func decide(
        text: String,
        speaker: SpeakerMatchDecision,
        timestamp: Date = .now
    ) -> VoiceFilterDecision {
        let relevance: ATCRelevanceDecision
        let indicator: ATCVoiceIndicator
        if enabled {
            relevance = gate.evaluate(text: text, speaker: speaker, timestamp: timestamp)
            indicator = Self.indicator(for: speaker, relevance: relevance)
        } else {
            relevance = .display(reason: .noCallSignConfigured)
            indicator = .filterOff
        }
        return VoiceFilterDecision(
            segmentText: text,
            speaker: speaker,
            relevance: relevance,
            indicator: indicator,
            timestamp: timestamp
        )
    }

    func routeBeforeTranscription(
        speaker: SpeakerMatchDecision
    ) -> PreTranscriptionRoutingDecision {
        guard enabled else { return .transcribe(reason: .filterDisabled) }
        guard !profiles.isEmpty else { return .transcribe(reason: .noPilotProfile) }
        switch speaker {
        case .pilot:
            return .discard(reason: .pilotVoice)
        case .nonPilot:
            return .transcribe(reason: .nonPilotVoice)
        case .mixed:
            return .transcribe(reason: .mixedOrLowConfidence)
        case .insufficientSpeech:
            return .discard(reason: .insufficientSpeech)
        }
    }

    private static func indicator(
        for speaker: SpeakerMatchDecision,
        relevance: ATCRelevanceDecision
    ) -> ATCVoiceIndicator {
        if case .pilot = speaker { return .pilotSuppressed }
        if case .insufficientSpeech = speaker { return .noiseOrTooShortSuppressed }
        if case .mixed = speaker { return .mixedSpeakerCandidate }

        switch relevance {
        case .display(reason: .callSignMatch):
            return .dispatcherAddressedOwnCallSign
        case .display(reason: .continuationOfRecentHit), .holdContinuation(reason: .continuationOfRecentHit):
            return .dispatcherContinuation
        case .display(reason: .noCallSignConfigured):
            return .probableDispatcher
        case .suppress(reason: .addressedToOther), .suppress(reason: .nonRelevant):
            return .otherTrafficSuppressed
        case .suppress(reason: .insufficientSpeech):
            return .noiseOrTooShortSuppressed
        case .suppress(reason: .pilotReadback):
            return .pilotSuppressed
        case .display(reason: _), .holdContinuation(reason: _):
            return .probableDispatcher
        case .suppress(reason: _):
            return .otherTrafficSuppressed
        }
    }

    func classify(
        samples: [Float],
        sampleRate: Double
    ) async throws -> SpeakerMatchDecision {
        guard enabled, !profiles.isEmpty else {
            return .nonPilot(bestPilotScore: 0)
        }
        return try await identifier.classify(
            samples: samples,
            sampleRate: sampleRate,
            profiles: profiles
        )
    }
}
