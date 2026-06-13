import Foundation

// why: FluidAudio speaker diarization (ADR 0008) is a PRD MVP non-goal/stretch, and ADR 0008
// requires its offline + simulator eval lanes green and thresholds calibrated before it ships
// behind the user toggle. Until then the production build hides the model-pack download +
// pilot-voice enrollment so the shipped default is the validated phase-1 callsign filter
// (ADR 0007). DEBUG builds and a launch arg opt in so the feature stays fully testable. Gating
// the UI is sufficient: without an installed pack and an enrolled pilot profile, the pre-ASR
// speaker path (VoiceFilterPipeline.routeBeforeTranscription / classify) fails open to .nonPilot,
// so the uncalibrated thresholds are never exercised in production.
enum VoiceFilterFeatureFlag {
  // why: ADR 0008's acceptance gates are met in-tree (real FluidAudioSpeakerIdentifier wired only
  // when the pack is installed; persisted state machine with round-trip test; download/import UX
  // with size disclosure, progress, cancel, retry, delete; network-deny integration test green on
  // the simulator; offline replay lane green in CI; 256-dim embedding asserted; live-state
  // capability copy) and the match thresholds are calibrated from real FluidAudio measurements — so
  // phase-2 speaker classification now ships ON by default. It stays SAFE by default: with no
  // installed pack and no enrolled pilot the pre-ASR speaker path fails open to .nonPilot (nothing
  // is suppressed) until the user explicitly downloads the pack and enrols a voice.
  // `-dspeech.voicefilter.diarization.disable` forces it off (test kill switch / safety override).
  static let speakerDiarizationEnabled: Bool =
    !CommandLine.arguments.contains("-dspeech.voicefilter.diarization.disable")
}

struct ModelPackAcquisition: Equatable, Sendable, Codable {
  enum Phase: String, Equatable, Sendable, Codable {
    case downloading
    case importing
  }

  let phase: Phase
  let fractionComplete: Double
  let bytesReceived: Int64?
  let totalBytes: Int64?

  init(
    phase: Phase,
    fractionComplete: Double,
    bytesReceived: Int64? = nil,
    totalBytes: Int64? = nil
  ) {
    self.phase = phase
    self.fractionComplete = min(max(fractionComplete, 0), 1)
    self.bytesReceived = bytesReceived
    self.totalBytes = totalBytes
  }

  var percentComplete: Int {
    Int((fractionComplete * 100).rounded())
  }
}

struct InstalledModelPack: Equatable, Sendable, Codable {
  let identifier: String
  let version: String
  let embeddingDimension: Int
  let checksumSHA256: String
  let source: String
  let sizeBytes: Int64
  let installedAt: Date
  let localModelPath: String?

  init(
    identifier: String,
    version: String,
    embeddingDimension: Int,
    checksumSHA256: String,
    source: String,
    sizeBytes: Int64,
    installedAt: Date,
    localModelPath: String? = nil
  ) {
    self.identifier = identifier
    self.version = version
    self.embeddingDimension = embeddingDimension
    self.checksumSHA256 = checksumSHA256
    self.source = source
    self.sizeBytes = sizeBytes
    self.installedAt = installedAt
    self.localModelPath = localModelPath
  }

  func replacingLocalModelPath(_ localModelPath: String?) -> InstalledModelPack {
    InstalledModelPack(
      identifier: identifier,
      version: version,
      embeddingDimension: embeddingDimension,
      checksumSHA256: checksumSHA256,
      source: source,
      sizeBytes: sizeBytes,
      installedAt: installedAt,
      localModelPath: localModelPath
    )
  }
}

struct ModelPackFailure: Equatable, Sendable, Codable {
  enum Kind: String, Equatable, Sendable, Codable {
    case network
    case checksum
    case dimensionMismatch
    case disk
    case cancelled
    case corruptState
    case unknown
  }

  let kind: Kind
  let userSafeReason: String
  let isRetryable: Bool
}

enum ModelPackState: Equatable, Sendable, Codable {
  case absent
  case acquiring(ModelPackAcquisition)
  case installed(InstalledModelPack)
  case failed(ModelPackFailure)
  case disabled(InstalledModelPack)

  var isInstalled: Bool {
    if case .installed = self { return true }
    return false
  }

  var installedPack: InstalledModelPack? {
    switch self {
    case .installed(let pack), .disabled(let pack):
      return pack
    case .absent, .acquiring, .failed:
      return nil
    }
  }

  var allowsEnrollment: Bool {
    isInstalled
  }

  var capabilityReason: String {
    switch self {
    case .absent:
      return
        String(
          localized:
            "The voice filter model isn't installed. Download the pack to enable pilot recognition."
        )
    case .acquiring(let acquisition):
      switch acquisition.phase {
      case .downloading:
        return String(localized: "Downloading the voice filter model…")
      case .importing:
        return String(localized: "Installing the voice filter model…")
      }
    case .installed:
      return String(
        localized: "The model is installed, but the local recognizer isn't available in this build."
      )
    case .failed(let failure):
      return failure.userSafeReason
    case .disabled:
      return String(localized: "Voice filter off. The model is installed and ready.")
    }
  }

  func recoveredAfterColdStart() -> ModelPackState {
    if case .acquiring = self {
      return .absent
    }
    return self
  }
}

protocol ModelPackStateStorage: Sendable {
  func loadState() -> ModelPackState
  func saveState(_ state: ModelPackState)
}

struct UserDefaultsModelPackStateStorage: ModelPackStateStorage, @unchecked Sendable {
  static let stateKey = "dspeech.voicefilter.modelpack.v1"

  let defaults: UserDefaults
  let applicationSupportDirectory: URL

  init(defaults: UserDefaults = .standard, applicationSupportDirectory: URL? = nil) {
    self.defaults = defaults
    self.applicationSupportDirectory =
      applicationSupportDirectory ?? Self.defaultApplicationSupportDirectory()
  }

  func loadState() -> ModelPackState {
    if let raw = defaults.string(forKey: Self.stateKey) {
      // why: a string at this key is only ever a UI-test launch-argument seam (production
      // persists JSON Data). Honor it in DEBUG/test builds only; in Release a string value is
      // treated as corrupt so the seam can never influence the shipped app.
      #if DEBUG
        if let launchState = Self.launchArgumentState(raw) {
          return launchState
        }
      #endif
      return .failed(Self.corruptPersistedStateFailure)
    }
    guard let data = defaults.data(forKey: Self.stateKey) else {
      return .absent
    }
    do {
      let decoded = try JSONDecoder().decode(ModelPackState.self, from: data)
      let recovered = decoded.recoveredAfterColdStart()
      let resolved = Self.resolvedModelPaths(
        in: recovered,
        applicationSupportDirectory: applicationSupportDirectory
      )
      let persisted = Self.persistedModelPaths(
        in: resolved,
        applicationSupportDirectory: applicationSupportDirectory
      )
      if persisted != decoded {
        saveState(resolved)
      }
      return resolved
    } catch {
      return .failed(Self.corruptPersistedStateFailure)
    }
  }

  func saveState(_ state: ModelPackState) {
    do {
      let persisted = Self.persistedModelPaths(
        in: state,
        applicationSupportDirectory: applicationSupportDirectory
      )
      let data = try JSONEncoder().encode(persisted)
      defaults.set(data, forKey: Self.stateKey)
    } catch {
      return
    }
  }

  #if DEBUG
    private static func launchArgumentState(_ raw: String) -> ModelPackState? {
      switch raw {
      case "absent":
        return .absent
      case "failedRetryable":
        return .failed(
          ModelPackFailure(
            kind: .network,
            userSafeReason:
              String(
                localized:
                  "Couldn't download the model pack. Check your network connection and try again."),
            isRetryable: true
          ))
      case "acquiringHalf":
        return .acquiring(
          ModelPackAcquisition(
            phase: .downloading,
            fractionComplete: 0.42,
            bytesReceived: 6_300_000,
            totalBytes: 15_000_000
          ))
      case "failedPermanent":
        return .failed(
          ModelPackFailure(
            kind: .unknown,
            userSafeReason: String(localized: "Model pack verification failed."),
            isRetryable: false
          ))
      default:
        return nil
      }
    }
  #endif

  private static let corruptPersistedStateFailure = ModelPackFailure(
    kind: .corruptState,
    userSafeReason:
      String(
        localized:
          "The saved state of the voice model pack is corrupted. Continue without the voice filter and re-download the pack if needed."
      ),
    isRetryable: false
  )

  private static func defaultApplicationSupportDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
  }

  private static func resolvedModelPaths(
    in state: ModelPackState,
    applicationSupportDirectory: URL
  ) -> ModelPackState {
    switch state {
    case .installed(let pack):
      return .installed(
        pack.replacingLocalModelPath(
          resolvedLocalModelPath(
            pack.localModelPath,
            applicationSupportDirectory: applicationSupportDirectory
          )))
    case .disabled(let pack):
      return .disabled(
        pack.replacingLocalModelPath(
          resolvedLocalModelPath(
            pack.localModelPath,
            applicationSupportDirectory: applicationSupportDirectory
          )))
    case .absent, .acquiring, .failed:
      return state
    }
  }

  private static func persistedModelPaths(
    in state: ModelPackState,
    applicationSupportDirectory: URL
  ) -> ModelPackState {
    switch state {
    case .installed(let pack):
      return .installed(
        pack.replacingLocalModelPath(
          persistedLocalModelPath(
            pack.localModelPath,
            applicationSupportDirectory: applicationSupportDirectory
          )))
    case .disabled(let pack):
      return .disabled(
        pack.replacingLocalModelPath(
          persistedLocalModelPath(
            pack.localModelPath,
            applicationSupportDirectory: applicationSupportDirectory
          )))
    case .absent, .acquiring, .failed:
      return state
    }
  }

  private static func resolvedLocalModelPath(
    _ path: String?,
    applicationSupportDirectory: URL
  ) -> String? {
    guard let path, !path.isEmpty else { return path }
    if path.hasPrefix("/") {
      let relative = relativePathInsideApplicationSupport(
        path,
        applicationSupportDirectory: applicationSupportDirectory
      )
      guard relative != path else { return path }
      return applicationSupportDirectory.appendingPathComponent(relative, isDirectory: true).path
    }
    return applicationSupportDirectory.appendingPathComponent(path, isDirectory: true).path
  }

  private static func persistedLocalModelPath(
    _ path: String?,
    applicationSupportDirectory: URL
  ) -> String? {
    guard let path, !path.isEmpty else { return path }
    return relativePathInsideApplicationSupport(
      path,
      applicationSupportDirectory: applicationSupportDirectory
    )
  }

  private static func relativePathInsideApplicationSupport(
    _ path: String,
    applicationSupportDirectory: URL
  ) -> String {
    guard path.hasPrefix("/") else { return path }
    let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
    let appSupportPath = applicationSupportDirectory.standardizedFileURL.path
    let prefix = appSupportPath.hasSuffix("/") ? appSupportPath : appSupportPath + "/"
    if standardizedPath.hasPrefix(prefix) {
      return String(standardizedPath.dropFirst(prefix.count))
    }
    let marker = "/Application Support/"
    guard let range = standardizedPath.range(of: marker) else {
      return path
    }
    return String(standardizedPath[range.upperBound...])
  }
}
