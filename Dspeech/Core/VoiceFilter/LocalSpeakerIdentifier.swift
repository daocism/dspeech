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
    reason: String =
      String(
        localized:
          "The on-device voice recognition model isn't installed in this build (see ADR 0007)."),
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

protocol LocalSpeakerBackendBuilder: Sendable {
  func makeIdentifier(for pack: InstalledModelPack) throws -> any LocalSpeakerIdentifier
}

enum LocalSpeakerIdentifierFactory {
  static func make(
    state: ModelPackState,
    backendBuilder: (any LocalSpeakerBackendBuilder)? = nil
  ) -> any LocalSpeakerIdentifier {
    guard case .installed(let pack) = state else {
      return UnavailableLocalSpeakerIdentifier(reason: state.capabilityReason)
    }
    guard let backendBuilder else {
      return UnavailableLocalSpeakerIdentifier(
        reason: state.capabilityReason,
        embeddingDimension: pack.embeddingDimension
      )
    }
    let identifier: any LocalSpeakerIdentifier
    do {
      identifier = try backendBuilder.makeIdentifier(for: pack)
    } catch {
      return UnavailableLocalSpeakerIdentifier(
        reason: String(
          localized: "Couldn't initialize the local recognizer from the installed pack."),
        embeddingDimension: pack.embeddingDimension
      )
    }
    guard case .available = identifier.availability else {
      return UnavailableLocalSpeakerIdentifier(
        reason: String(
          localized: "The local recognizer reported unavailable after the pack was installed."),
        embeddingDimension: pack.embeddingDimension
      )
    }
    guard identifier.embeddingDimension == pack.embeddingDimension else {
      return UnavailableLocalSpeakerIdentifier(
        reason:
          String(
            localized:
              "The recognizer’s embedding dimension (\(identifier.embeddingDimension)) doesn’t match the pack (\(pack.embeddingDimension))."
          ),
        embeddingDimension: pack.embeddingDimension
      )
    }
    return identifier
  }
}
