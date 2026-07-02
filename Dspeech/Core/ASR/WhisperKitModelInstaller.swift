import Foundation
import Observation

enum WhisperKitModelInstallError: Error, Equatable {
  case cancelled
  case invalidURL(String)
  case fileMissingAfterDownload(String)
  case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
  // why: B4 closed the fail-open integrity gap — WhisperKit now verifies each downloaded file
  // against a baked-in per-file SHA-256 (pinned HF revision, ADR-0011), exactly like Parakeet. A
  // mismatch is surfaced, never swallowed and never fail-open: a tampered/corrupt CoreML bundle
  // must not be loaded.
  case checksumMismatch(relativePath: String, expected: String, actual: String)
}

struct WhisperKitModelDownloadProgress: Equatable, Sendable, Codable {
  let fractionComplete: Double
  let bytesReceived: Int64
  let totalBytes: Int64

  init(fractionComplete: Double, bytesReceived: Int64, totalBytes: Int64) {
    self.fractionComplete = min(max(fractionComplete, 0), 1)
    self.bytesReceived = bytesReceived
    self.totalBytes = totalBytes
  }

  var percentComplete: Int {
    Int((fractionComplete * 100).rounded())
  }
}

struct WhisperKitInstalledModelFile: Equatable, Sendable, Codable {
  let relativePath: String
  let sha256: String
  let sizeBytes: Int64
}

struct WhisperKitInstalledModel: Equatable, Sendable, Codable {
  let name: String
  let repository: String
  let revision: String
  let files: [WhisperKitInstalledModelFile]
  let sizeBytes: Int64
  let installedAt: Date
  let localModelPath: String?

  func replacingLocalModelPath(_ localModelPath: String?) -> WhisperKitInstalledModel {
    WhisperKitInstalledModel(
      name: name,
      repository: repository,
      revision: revision,
      files: files,
      sizeBytes: sizeBytes,
      installedAt: installedAt,
      localModelPath: localModelPath
    )
  }
}

struct WhisperKitModelInstallFailure: Equatable, Sendable, Codable {
  enum Kind: String, Equatable, Sendable, Codable {
    case network
    // why: C2 — a specifically offline device (airplane mode / dropped Wi-Fi or cellular /
    // cellular-data disallowed) gets its own kind + copy, distinct from a generic server-side
    // network failure, so the pilot is told to reconnect rather than to "check the connection".
    case offline
    case checksum
    case disk
    case cancelled
    case corruptState
    case unknown
  }

  let kind: Kind
  let userSafeReason: String
  let isRetryable: Bool
}

enum WhisperKitModelInstallState: Equatable, Sendable, Codable {
  case absent
  case downloading(WhisperKitModelDownloadProgress)
  case installed(WhisperKitInstalledModel)
  case failed(WhisperKitModelInstallFailure)

  var installedModel: WhisperKitInstalledModel? {
    if case .installed(let model) = self { return model }
    return nil
  }

  var isInstalled: Bool {
    installedModel != nil
  }

  func recoveredAfterColdStart() -> WhisperKitModelInstallState {
    if case .downloading = self { return .absent }
    return self
  }
}

extension WhisperKitModelInstallState: PinnedModelPersistentState {
  static var absentState: WhisperKitModelInstallState { .absent }

  var installedLocalModelPath: String? { installedModel?.localModelPath }

  func replacingInstalledLocalModelPath(_ path: String?) -> WhisperKitModelInstallState {
    guard case .installed(let model) = self else { return self }
    return .installed(model.replacingLocalModelPath(path))
  }
}

protocol WhisperKitModelStateStorage: Sendable {
  func loadState() -> WhisperKitModelInstallState
  func saveState(_ state: WhisperKitModelInstallState)
}

struct UserDefaultsWhisperKitModelStateStorage: WhisperKitModelStateStorage, @unchecked Sendable {
  static let stateKey = "dspeech.whisperkit.model.v1"

  let defaults: UserDefaults
  let applicationSupportDirectory: URL

  init(defaults: UserDefaults = .standard, applicationSupportDirectory: URL? = nil) {
    self.defaults = defaults
    self.applicationSupportDirectory =
      applicationSupportDirectory ?? ApplicationSupport.directoryOrTrap()
  }

  func loadState() -> WhisperKitModelInstallState {
    loadPinnedModelState(
      defaults: defaults,
      key: Self.stateKey,
      applicationSupportDirectory: applicationSupportDirectory,
      corruptStateFallback: { .failed(Self.corruptPersistedStateFailure) },
      saveResolved: { saveState($0) }
    )
  }

  func saveState(_ state: WhisperKitModelInstallState) {
    savePinnedModelState(
      state,
      defaults: defaults,
      key: Self.stateKey,
      applicationSupportDirectory: applicationSupportDirectory,
      // why: the protocol is non-throwing, but a persistence failure must not vanish silently — at
      // least leave a diagnostic trail (the installed state may then fail to survive relaunch).
      onEncodeError: {
        DspeechLog.engine.error(
          "whisperkit model state save failed error=\($0.localizedDescription, privacy: .public)")
      }
    )
  }

  private static let corruptPersistedStateFailure = WhisperKitModelInstallFailure(
    kind: .corruptState,
    userSafeReason:
      String(
        localized:
          "The saved WhisperKit model state is corrupted. Continue with Apple Speech and re-download the model if needed."
      ),
    isRetryable: false
  )
}

protocol WhisperKitModelFileDownloading: Sendable {
  func download(from sourceURL: URL, to destinationURL: URL) async throws
}

struct URLSessionWhisperKitModelFileDownloader: WhisperKitModelFileDownloading {
  func download(from sourceURL: URL, to destinationURL: URL) async throws {
    // why: C1 — stage into `<destination>.partial` and resume from its byte count via an HTTP
    // `Range` request, so an interrupted multi-hundred-MB CoreML download continues instead of
    // restarting at zero. The pinned per-file SHA-256 is still verified over the complete assembled
    // file by the shared engine, so a corrupt/short partial can never fail-open.
    try await resumableStagedDownload(to: destinationURL) { fromByteOffset in
      var request = URLRequest(url: sourceURL)
      if fromByteOffset > 0 {
        request.setValue("bytes=\(fromByteOffset)-", forHTTPHeaderField: "Range")
      }
      let (temporaryURL, response) = try await URLSession.shared.download(for: request)
      return try stagePinnedDownloadResponse(
        temporaryURL: temporaryURL, response: response, destination: destinationURL)
    }
  }
}

@MainActor
@Observable
final class WhisperKitModelInstaller {
  struct ExpectedModelFile: Equatable, Sendable {
    let relativePath: String
    let sizeBytes: Int64
    let expectedSHA256: String
  }

  nonisolated static let modelName = "large-v3-v20240930_626MB"
  nonisolated static let modelFolderName = "openai_whisper-large-v3-v20240930_626MB"
  nonisolated static let repository = "argmaxinc/whisperkit-coreml"
  // why: supply-chain policy forbids downloading mutable Hugging Face main; this is main as resolved on 2026-06-12.
  nonisolated static let pinnedRevision = "97a5bf9bbc74c7d9c12c755d04dea59e672e3808"
  // why: per-file SHA-256 baked in from the pinned revision (measured 2026-07-02 by downloading each
  // file from the pinned HF URL and hashing it; sizes match this manifest exactly). B4 verifies every
  // downloaded file against these before install — no fail-open, no unverified files.
  nonisolated static let expectedModelFiles: [ExpectedModelFile] = [
    ExpectedModelFile(
      relativePath: "AudioEncoder.mlmodelc/analytics/coremldata.bin",
      sizeBytes: 243,
      expectedSHA256: "56793886ab1adb9ca8a4e335efbe8af6640f40d958ab2d29c3ad2d7d6f712e95"
    ),
    ExpectedModelFile(
      relativePath: "AudioEncoder.mlmodelc/coremldata.bin",
      sizeBytes: 348,
      expectedSHA256: "ffa9eb76e8e9d9be75a4d527e5249e61d67fd43081c5aa110fd24efa6c8c5ea3"
    ),
    ExpectedModelFile(
      relativePath: "AudioEncoder.mlmodelc/metadata.json",
      sizeBytes: 1_922,
      expectedSHA256: "a87a3375afe79e88e27af30247e234e706b98679dedfd1b021a74f7ee108c669"
    ),
    ExpectedModelFile(
      relativePath: "AudioEncoder.mlmodelc/model.mil",
      sizeBytes: 934_263,
      expectedSHA256: "3cec2580fb07b12a88087f0e1586c6ba2982980eb36499561e1ffca2b0950442"
    ),
    ExpectedModelFile(
      relativePath: "AudioEncoder.mlmodelc/weights/weight.bin",
      sizeBytes: 421_968_768,
      expectedSHA256: "e4740fa28ed65907af754af893dfce98473fafb84dd8d718ad346985fe7678c1"
    ),
    ExpectedModelFile(
      relativePath: "MelSpectrogram.mlmodelc/analytics/coremldata.bin",
      sizeBytes: 243,
      expectedSHA256: "c5be419f8622083ac7046306400643539f0e7577c843448c36defc090d41e7ce"
    ),
    ExpectedModelFile(
      relativePath: "MelSpectrogram.mlmodelc/coremldata.bin",
      sizeBytes: 329,
      expectedSHA256: "2bfc12cffc2e45e039c7a18f384f09adffb72c182fcd93f9413d405d1a6c1130"
    ),
    ExpectedModelFile(
      relativePath: "MelSpectrogram.mlmodelc/metadata.json",
      sizeBytes: 1_850,
      expectedSHA256: "2bc552e09a6f124d9e6c178dd1a6979e010206acb26308b2224887c9dcbeb35f"
    ),
    ExpectedModelFile(
      relativePath: "MelSpectrogram.mlmodelc/model.mil",
      sizeBytes: 10_143,
      expectedSHA256: "c270b95b5f81d7f7d0b8a3e8f991d4e5812a37cad29349868a35b91f3a6a4463"
    ),
    ExpectedModelFile(
      relativePath: "MelSpectrogram.mlmodelc/weights/weight.bin",
      sizeBytes: 373_376,
      expectedSHA256: "009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49"
    ),
    ExpectedModelFile(
      relativePath: "TextDecoder.mlmodelc/analytics/coremldata.bin",
      sizeBytes: 243,
      expectedSHA256: "3913b8c9716b284a917cf3744f4d415f2a05e2b910594a14c6cc10092284d3f8"
    ),
    ExpectedModelFile(
      relativePath: "TextDecoder.mlmodelc/coremldata.bin",
      sizeBytes: 633,
      expectedSHA256: "3faabaf66930e66956d8291d0ff485fb382496e30a91a7185548b9b898ce90a9"
    ),
    ExpectedModelFile(
      relativePath: "TextDecoder.mlmodelc/metadata.json",
      sizeBytes: 4_924,
      expectedSHA256: "994f6030d7b1a8be999940444c3cf5d6a57d40ddd4423cf1d1fc93520aa1b052"
    ),
    ExpectedModelFile(
      relativePath: "TextDecoder.mlmodelc/model.mil",
      sizeBytes: 217_177,
      expectedSHA256: "dbe833be9e64348c95b7fa598d0ae4309a91aedce4e82fa500a714b0e4b5d754"
    ),
    ExpectedModelFile(
      relativePath: "TextDecoder.mlmodelc/weights/weight.bin",
      sizeBytes: 203_199_860,
      expectedSHA256: "d69700903d518ada33170ab77faaaf464496fb9ff65752c6d5a6109aa2fb02db"
    ),
    ExpectedModelFile(
      relativePath: "config.json",
      sizeBytes: 1_149,
      expectedSHA256: "f01d83dd891791d6f12421c05d3ed8ebbe70866f10d6c9a7a7e80b558ce5a0f1"
    ),
    ExpectedModelFile(
      relativePath: "generation_config.json",
      sizeBytes: 2_767,
      expectedSHA256: "7fbb053a023be11fbeccd8421811610308143daa93d9617c52aab4a0fa1491c6"
    ),
  ]
  nonisolated static let expectedModelSizeBytes: Int64 = expectedModelFiles.reduce(0) {
    $0 + $1.sizeBytes
  }

  private(set) var state: WhisperKitModelInstallState

  private let stateStorage: any WhisperKitModelStateStorage
  private let fileDownloader: any WhisperKitModelFileDownloading
  private let applicationSupportDirectory: URL
  private let availableCapacityProvider: @Sendable (URL) throws -> Int64
  private let now: @Sendable () -> Date
  // why: defaults to the pinned production manifest. Injectable ONLY so tests can exercise the
  // SHA-256 verification path with content they control — real model bytes can't be reproduced from
  // a fake downloader (preimage resistance), so the happy install path needs a manifest whose hashes
  // match the fixture content. Production always uses the static default.
  private let expectedFiles: [ExpectedModelFile]
  private let expectedFilesSizeBytes: Int64

  init(
    stateStorage: any WhisperKitModelStateStorage = UserDefaultsWhisperKitModelStateStorage(),
    fileDownloader: any WhisperKitModelFileDownloading = URLSessionWhisperKitModelFileDownloader(),
    applicationSupportDirectory: URL? = nil,
    availableCapacityProvider: @escaping @Sendable (URL) throws -> Int64 = {
      try ModelInstallFileSystem.availableCapacity(at: $0)
    },
    now: @escaping @Sendable () -> Date = Date.init,
    expectedFiles: [ExpectedModelFile] = WhisperKitModelInstaller.expectedModelFiles
  ) {
    self.stateStorage = stateStorage
    self.fileDownloader = fileDownloader
    self.applicationSupportDirectory =
      applicationSupportDirectory ?? ApplicationSupport.directoryOrTrap()
    self.availableCapacityProvider = availableCapacityProvider
    self.now = now
    self.expectedFiles = expectedFiles
    self.expectedFilesSizeBytes = expectedFiles.reduce(0) { $0 + $1.sizeBytes }
    self.state = stateStorage.loadState()
  }

  var installedModelFolderURL: URL? {
    guard let path = state.installedModel?.localModelPath, !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  private var modelsRootURL: URL {
    applicationSupportDirectory.appendingPathComponent("WhisperKit/Models", isDirectory: true)
  }

  // why: C3 read-only accessors over the C1 resume cache — the UI shows a "Resume download" CTA and
  // "N% kept" copy when a paused/cancelled attempt left staged bytes behind. No download logic here;
  // these only stat the staging folder.
  var partialStagingByteCount: Int64 {
    pinnedModelStagedByteCount(modelsRoot: modelsRootURL, modelFolderName: Self.modelFolderName)
  }

  var hasPartialStaging: Bool { partialStagingByteCount > 0 }

  var stagedFractionKept: Double {
    guard expectedFilesSizeBytes > 0 else { return 0 }
    return min(1, Double(partialStagingByteCount) / Double(expectedFilesSizeBytes))
  }

  func install() async {
    do {
      let model = try await downloadAndInstallModel()
      transition(to: .installed(model))
    } catch {
      transition(to: .failed(whisperKitModelDownloadFailure(for: error)))
    }
  }

  func deleteInstalledModel() async {
    do {
      if let installedModelFolderURL {
        try ModelInstallFileSystem.removeIfPresent(installedModelFolderURL)
      }
      // why: reclaim any orphan resume-cache staging from an abandoned interrupted download (C1).
      try? ModelInstallFileSystem.removeIfPresent(
        pinnedModelStagingRoot(modelsRoot: modelsRootURL, modelFolderName: Self.modelFolderName))
      transition(to: .absent)
    } catch {
      transition(to: .failed(whisperKitModelDeleteFailure(for: error)))
    }
  }

  nonisolated static func pinnedDownloadURL(relativePath: String) throws -> URL {
    let encodedPath =
      relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
    let urlString =
      "https://huggingface.co/\(repository)/resolve/\(pinnedRevision)/\(modelFolderName)/\(encodedPath)"
    guard let url = URL(string: urlString) else {
      throw WhisperKitModelInstallError.invalidURL(urlString)
    }
    return url
  }

  nonisolated static func preflightSufficientFreeSpace(
    availableBytes: Int64,
    expectedModelSizeBytes: Int64 = WhisperKitModelInstaller.expectedModelSizeBytes
  ) throws {
    try preflightPinnedModelFreeSpace(
      availableBytes: availableBytes,
      expectedModelSizeBytes: expectedModelSizeBytes
    ) {
      WhisperKitModelInstallError.insufficientDiskSpace(requiredBytes: $0, availableBytes: $1)
    }
  }

  private func downloadAndInstallModel() async throws -> WhisperKitInstalledModel {
    let modelsRoot = modelsRootURL
    try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    try ModelInstallFileSystem.excludeFromBackup(modelsRoot)
    try Self.preflightSufficientFreeSpace(
      availableBytes: availableCapacityProvider(modelsRoot),
      expectedModelSizeBytes: expectedFilesSizeBytes
    )

    let totalBytes = expectedFilesSizeBytes
    let staged = try await downloadAndStagePinnedModel(
      modelsRoot: modelsRoot,
      modelFolderName: Self.modelFolderName,
      specs: expectedFiles.map {
        PinnedModelFileSpec(
          relativePath: $0.relativePath,
          sizeBytes: $0.sizeBytes,
          expectedSHA256: $0.expectedSHA256
        )
      },
      sourceURL: { try Self.pinnedDownloadURL(relativePath: $0) },
      download: { try await self.fileDownloader.download(from: $0, to: $1) },
      fileMissing: { WhisperKitModelInstallError.fileMissingAfterDownload($0) },
      checksumMismatch: {
        WhisperKitModelInstallError.checksumMismatch(relativePath: $0, expected: $1, actual: $2)
      },
      onProgress: { completedBytes in
        self.transition(
          to: .downloading(
            WhisperKitModelDownloadProgress(
              fractionComplete: totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0,
              bytesReceived: completedBytes,
              totalBytes: totalBytes
            )))
      }
    )

    return WhisperKitInstalledModel(
      name: Self.modelName,
      repository: Self.repository,
      revision: Self.pinnedRevision,
      files: staged.files.map {
        WhisperKitInstalledModelFile(
          relativePath: $0.relativePath,
          sha256: $0.sha256,
          sizeBytes: $0.sizeBytes
        )
      },
      sizeBytes: staged.sizeBytes,
      installedAt: now(),
      localModelPath: staged.finalModelFolder.path
    )
  }

  private func transition(to newState: WhisperKitModelInstallState) {
    state = newState
    stateStorage.saveState(newState)
  }
}

func whisperKitModelDownloadFailure(for error: Error) -> WhisperKitModelInstallFailure {
  switch classifyPinnedModelDownloadFailure(
    error,
    isChecksumMismatch: {
      if case .checksumMismatch = $0 as? WhisperKitModelInstallError { return true }
      return false
    },
    isDiskFull: isWhisperKitDiskFull,
    isCancelled: { $0 as? WhisperKitModelInstallError == .cancelled }
  ) {
  case .checksum:
    return WhisperKitModelInstallFailure(
      kind: .checksum,
      userSafeReason:
        String(
          localized:
            "The downloaded WhisperKit model failed its integrity check and was discarded. Try downloading again."
        ),
      isRetryable: true
    )
  case .disk:
    return WhisperKitModelInstallFailure(
      kind: .disk,
      userSafeReason:
        String(
          localized:
            "There isn't enough device storage to install the WhisperKit model. Free storage and try again."
        ),
      isRetryable: true
    )
  case .cancelled:
    return WhisperKitModelInstallFailure(
      kind: .cancelled,
      userSafeReason: String(localized: "The WhisperKit model download was cancelled."),
      isRetryable: true
    )
  case .offline:
    return WhisperKitModelInstallFailure(
      kind: .offline,
      userSafeReason:
        String(
          localized:
            "You appear to be offline. Reconnect to the internet and try again to download the WhisperKit model."
        ),
      isRetryable: true
    )
  case .network:
    return WhisperKitModelInstallFailure(
      kind: .network,
      userSafeReason:
        String(
          localized:
            "Couldn't download the WhisperKit model because the network request failed. Check your connection and try again."
        ),
      isRetryable: true
    )
  case .unknown:
    return WhisperKitModelInstallFailure(
      kind: .unknown,
      userSafeReason:
        String(localized: "Couldn't install the WhisperKit model on this device."),
      isRetryable: false
    )
  }
}

func whisperKitModelDeleteFailure(for error: Error) -> WhisperKitModelInstallFailure {
  WhisperKitModelInstallFailure(
    kind: .disk,
    userSafeReason:
      String(
        localized:
          "Couldn't delete the WhisperKit model from the device. The device reported a storage or file-access error. Try again later."
      ),
    isRetryable: false
  )
}

private func isWhisperKitDiskFull(_ error: Error) -> Bool {
  if case .insufficientDiskSpace = error as? WhisperKitModelInstallError {
    return true
  }
  return isModelInstallDiskFullNSError(error)
}
