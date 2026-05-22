import Foundation

enum LocalSpeakerIdentifierAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

enum LocalSpeakerIdentifierError: Error, Equatable, Sendable {
    case modelUnavailable(reason: String)
    case insufficientSpeech
    case incompatibleDimension(expected: Int, got: Int)
    case captureFailed(reason: String)
}

protocol LocalSpeakerIdentifier: Sendable {
    var availability: LocalSpeakerIdentifierAvailability { get }
    var embeddingDimension: Int { get }

    func enroll(samples: [Float], sampleRate: Double) async throws -> VoicePrintVector
    func classify(
        samples: [Float],
        sampleRate: Double,
        profiles: [PilotVoiceProfile]
    ) async throws -> SpeakerMatchDecision
}

struct UnavailableLocalSpeakerIdentifier: LocalSpeakerIdentifier {
    let reason: String
    let embeddingDimension: Int

    init(
        reason: String = "Локальная модель распознавания голоса не установлена в этой сборке (см. ADR 0007).",
        embeddingDimension: Int = 256
    ) {
        self.reason = reason
        self.embeddingDimension = embeddingDimension
    }

    var availability: LocalSpeakerIdentifierAvailability {
        .unavailable(reason: reason)
    }

    func enroll(samples: [Float], sampleRate: Double) async throws -> VoicePrintVector {
        _ = samples
        _ = sampleRate
        throw LocalSpeakerIdentifierError.modelUnavailable(reason: reason)
    }

    func classify(
        samples: [Float],
        sampleRate: Double,
        profiles: [PilotVoiceProfile]
    ) async throws -> SpeakerMatchDecision {
        _ = samples
        _ = sampleRate
        _ = profiles
        throw LocalSpeakerIdentifierError.modelUnavailable(reason: reason)
    }
}
