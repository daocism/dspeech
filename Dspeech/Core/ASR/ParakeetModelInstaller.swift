import Foundation
import Observation

enum ParakeetModelInstallError: Error, Equatable {
  case cancelled
  case invalidURL(String)
  case fileMissingAfterDownload(String)
  case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
  // why: Parakeet verifies each downloaded file against a baked-in per-file SHA-256 (supply-chain
  // pinning, ADR-0012). A mismatch is surfaced, never swallowed and never fail-open: a tampered or
  // corrupted CoreML bundle must not be loaded.
  case checksumMismatch(relativePath: String, expected: String, actual: String)
}

struct ParakeetModelDownloadProgress: Equatable, Sendable, Codable {
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

struct ParakeetInstalledModelFile: Equatable, Sendable, Codable {
  let relativePath: String
  let sha256: String
  let sizeBytes: Int64
}

struct ParakeetInstalledModel: Equatable, Sendable, Codable {
  let name: String
  let repository: String
  let revision: String
  let files: [ParakeetInstalledModelFile]
  let sizeBytes: Int64
  let installedAt: Date
  let localModelPath: String?

  func replacingLocalModelPath(_ localModelPath: String?) -> ParakeetInstalledModel {
    ParakeetInstalledModel(
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

struct ParakeetModelInstallFailure: Equatable, Sendable, Codable {
  enum Kind: String, Equatable, Sendable, Codable {
    case network
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

enum ParakeetModelInstallState: Equatable, Sendable, Codable {
  case absent
  case downloading(ParakeetModelDownloadProgress)
  case installed(ParakeetInstalledModel)
  case failed(ParakeetModelInstallFailure)

  var installedModel: ParakeetInstalledModel? {
    if case .installed(let model) = self { return model }
    return nil
  }

  var isInstalled: Bool {
    installedModel != nil
  }

  func recoveredAfterColdStart() -> ParakeetModelInstallState {
    if case .downloading = self { return .absent }
    return self
  }
}

protocol ParakeetModelStateStorage: Sendable {
  func loadState() -> ParakeetModelInstallState
  func saveState(_ state: ParakeetModelInstallState)
}

struct UserDefaultsParakeetModelStateStorage: ParakeetModelStateStorage, @unchecked Sendable {
  static let stateKey = "dspeech.parakeet.model.v1"

  let defaults: UserDefaults
  let applicationSupportDirectory: URL

  init(defaults: UserDefaults = .standard, applicationSupportDirectory: URL? = nil) {
    self.defaults = defaults
    self.applicationSupportDirectory =
      applicationSupportDirectory ?? ApplicationSupport.directoryOrTrap()
  }

  func loadState() -> ParakeetModelInstallState {
    guard let data = defaults.data(forKey: Self.stateKey) else {
      return .absent
    }
    do {
      let decoded = try JSONDecoder().decode(ParakeetModelInstallState.self, from: data)
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

  func saveState(_ state: ParakeetModelInstallState) {
    do {
      let persisted = Self.persistedModelPaths(
        in: state,
        applicationSupportDirectory: applicationSupportDirectory
      )
      let data = try JSONEncoder().encode(persisted)
      defaults.set(data, forKey: Self.stateKey)
    } catch {
      // why: the protocol is non-throwing, but a persistence failure must not vanish silently — at
      // least leave a diagnostic trail (the installed state may then fail to survive relaunch).
      DspeechLog.engine.error(
        "parakeet model state save failed error=\(error.localizedDescription, privacy: .public)")
    }
  }

  private static let corruptPersistedStateFailure = ParakeetModelInstallFailure(
    kind: .corruptState,
    userSafeReason:
      String(
        localized:
          "The saved Parakeet model state is corrupted. Continue with Apple Speech and re-download the model if needed."
      ),
    isRetryable: false
  )

  private static func resolvedModelPaths(
    in state: ParakeetModelInstallState,
    applicationSupportDirectory: URL
  ) -> ParakeetModelInstallState {
    switch state {
    case .installed(let model):
      return .installed(
        model.replacingLocalModelPath(
          ApplicationSupportRelativePath.resolved(
            model.localModelPath,
            applicationSupportDirectory: applicationSupportDirectory
          )))
    case .absent, .downloading, .failed:
      return state
    }
  }

  private static func persistedModelPaths(
    in state: ParakeetModelInstallState,
    applicationSupportDirectory: URL
  ) -> ParakeetModelInstallState {
    switch state {
    case .installed(let model):
      return .installed(
        model.replacingLocalModelPath(
          ApplicationSupportRelativePath.persisted(
            model.localModelPath,
            applicationSupportDirectory: applicationSupportDirectory
          )))
    case .absent, .downloading, .failed:
      return state
    }
  }
}

protocol ParakeetModelFileDownloading: Sendable {
  func download(from sourceURL: URL, to destinationURL: URL) async throws
}

struct URLSessionParakeetModelFileDownloader: ParakeetModelFileDownloading {
  func download(from sourceURL: URL, to destinationURL: URL) async throws {
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let request = URLRequest(url: sourceURL)
    let (temporaryURL, response) = try await URLSession.shared.download(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw URLError(.badServerResponse)
    }
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      try FileManager.default.removeItem(at: destinationURL)
    }
    try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
  }
}

@MainActor
@Observable
final class ParakeetModelInstaller {
  struct ExpectedModelFile: Equatable, Sendable {
    let relativePath: String
    let sizeBytes: Int64
    let expectedSHA256: String
  }

  nonisolated static let modelName = "parakeet-realtime-eou-120m"
  // why: the chunk-variant subfolder doubles as the HF subpath and the on-disk leaf folder
  // FluidAudio's StreamingEouAsrManager.loadModels(from:) reads from. ADR-0012 ships only 160ms.
  nonisolated static let modelFolderName = "160ms"
  nonisolated static let repository = "FluidInference/parakeet-realtime-eou-120m-coreml"
  // why: supply-chain policy forbids the mutable HF main branch; this is the pinned revision
  // resolved against HuggingFace on 2026-06-23 (PLAN-2026-06-22 Phase 1).
  nonisolated static let sourceRevision = "40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355"
  // why: the directory FluidAudio's manual loader reads from —
  // Application Support/FluidAudio/Models/parakeet-realtime-eou-120m-coreml/160ms/.
  nonisolated static let modelsRootComponent = "FluidAudio/Models/parakeet-realtime-eou-120m-coreml"
  nonisolated static let expectedModelFiles: [ExpectedModelFile] = [
    ExpectedModelFile(
      relativePath: "streaming_encoder.mlmodelc/analytics/coremldata.bin",
      sizeBytes: 243,
      expectedSHA256: "a981b257db79b4f86e6fa06a92562160a0ae71554746c24af24d8634b85f0356"
    ),
    ExpectedModelFile(
      relativePath: "streaming_encoder.mlmodelc/coremldata.bin",
      sizeBytes: 670,
      expectedSHA256: "e762abc60d999bcd10aab985b68191a602f2e8e03165cf08671c60f93936037a"
    ),
    ExpectedModelFile(
      relativePath: "streaming_encoder.mlmodelc/metadata.json",
      sizeBytes: 5_327,
      expectedSHA256: "75be31534cdd91711b08ba3a46046523eb9be9909618cd569cce1ea79e842a95"
    ),
    ExpectedModelFile(
      relativePath: "streaming_encoder.mlmodelc/model.mil",
      sizeBytes: 639_646,
      expectedSHA256: "709f9280eb0bba1fd698cc252275ba802885c2c53cdb60d399277281dac09b5d"
    ),
    ExpectedModelFile(
      relativePath: "streaming_encoder.mlmodelc/weights/weight.bin",
      sizeBytes: 212_691_776,
      expectedSHA256: "12cd781a4300b52b6687587b7d8e37e0ce5c8ccb1dbea036008275e6abf5070c"
    ),
    ExpectedModelFile(
      relativePath: "decoder.mlmodelc/analytics/coremldata.bin",
      sizeBytes: 243,
      expectedSHA256: "3996975a8cbc1949159c55605b3132b39b2484f51acbd55d796d93c70de02b49"
    ),
    ExpectedModelFile(
      relativePath: "decoder.mlmodelc/coremldata.bin",
      sizeBytes: 497,
      expectedSHA256: "c3ccbff963d8cf07e2be2bd56ea3384a89ea49628922c6bd95ff62e2ae57dc34"
    ),
    ExpectedModelFile(
      relativePath: "decoder.mlmodelc/metadata.json",
      sizeBytes: 3_283,
      expectedSHA256: "0977480649f2756894b0acfe2fdf4231a991f25e3fe02562bfb71b65ca944575"
    ),
    ExpectedModelFile(
      relativePath: "decoder.mlmodelc/model.mil",
      sizeBytes: 7_409,
      expectedSHA256: "b7c084a35bdbc887d69d6226cd533e2c11b2792c37d7352cf878f9f6f3c13555"
    ),
    ExpectedModelFile(
      relativePath: "decoder.mlmodelc/weights/weight.bin",
      sizeBytes: 7_873_600,
      expectedSHA256: "0b4cacecdcd9df79ab1e56de67230baf5a8664d2afe0bb8f3408eefa972cb2f4"
    ),
    ExpectedModelFile(
      relativePath: "joint_decision.mlmodelc/analytics/coremldata.bin",
      sizeBytes: 243,
      expectedSHA256: "5bca32ad130dcad6605cc00044c752aa5b45ef57d14c17f2d1a2fa49d6cf55b5"
    ),
    ExpectedModelFile(
      relativePath: "joint_decision.mlmodelc/coremldata.bin",
      sizeBytes: 493,
      expectedSHA256: "22d4abc4625b935ee035b5f8ce7cb28d1041b9b01c12173e287bf4b5f5d99625"
    ),
    ExpectedModelFile(
      relativePath: "joint_decision.mlmodelc/metadata.json",
      sizeBytes: 3_181,
      expectedSHA256: "e970ae87137730020690d24d971813db3633bbdfed602d43b6a9c84deced6dc8"
    ),
    ExpectedModelFile(
      relativePath: "joint_decision.mlmodelc/model.mil",
      sizeBytes: 9_608,
      expectedSHA256: "45e8590bc87e34c162b547e43a4f60e64db15b017f48395d7835a6867884804f"
    ),
    ExpectedModelFile(
      relativePath: "joint_decision.mlmodelc/weights/weight.bin",
      sizeBytes: 2_794_182,
      expectedSHA256: "7039b2010a269153f5a96edf28637f921a86ef8822f248f2d6712f7a6bce84b4"
    ),
    ExpectedModelFile(
      relativePath: "vocab.json",
      sizeBytes: 17_437,
      expectedSHA256: "83fd42ad33dae1bd3ceee6c0bb6c625f314cf0b2dc8430be441ac1e2643d5c36"
    ),
  ]
  nonisolated static let expectedModelSizeBytes: Int64 = expectedModelFiles.reduce(0) {
    $0 + $1.sizeBytes
  }

  private(set) var state: ParakeetModelInstallState

  private let stateStorage: any ParakeetModelStateStorage
  private let fileDownloader: any ParakeetModelFileDownloading
  private let applicationSupportDirectory: URL
  private let availableCapacityProvider: @Sendable (URL) throws -> Int64
  private let now: @Sendable () -> Date
  // why: defaults to the pinned production manifest. Injectable ONLY so tests can exercise the
  // SHA-256 verification path with content they control — real model bytes can't be reproduced
  // from a fake downloader (preimage resistance), so the happy install path needs a manifest
  // whose hashes match the fixture content. Production always uses the static default.
  private let expectedFiles: [ExpectedModelFile]
  private let expectedFilesSizeBytes: Int64

  init(
    stateStorage: any ParakeetModelStateStorage = UserDefaultsParakeetModelStateStorage(),
    fileDownloader: any ParakeetModelFileDownloading = URLSessionParakeetModelFileDownloader(),
    applicationSupportDirectory: URL? = nil,
    availableCapacityProvider: @escaping @Sendable (URL) throws -> Int64 = {
      try ModelInstallFileSystem.availableCapacity(at: $0)
    },
    now: @escaping @Sendable () -> Date = Date.init,
    expectedFiles: [ExpectedModelFile] = ParakeetModelInstaller.expectedModelFiles
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

  func install() async {
    do {
      let model = try await downloadAndInstallModel()
      transition(to: .installed(model))
    } catch {
      transition(to: .failed(parakeetModelDownloadFailure(for: error)))
    }
  }

  func deleteInstalledModel() async {
    do {
      if let installedModelFolderURL {
        try ModelInstallFileSystem.removeIfPresent(installedModelFolderURL)
      }
      transition(to: .absent)
    } catch {
      transition(to: .failed(parakeetModelDeleteFailure(for: error)))
    }
  }

  nonisolated static func pinnedDownloadURL(relativePath: String) throws -> URL {
    let encodedPath =
      relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
    let urlString =
      "https://huggingface.co/\(repository)/resolve/\(sourceRevision)/\(modelFolderName)/\(encodedPath)"
    guard let url = URL(string: urlString) else {
      throw ParakeetModelInstallError.invalidURL(urlString)
    }
    return url
  }

  nonisolated static func preflightSufficientFreeSpace(
    availableBytes: Int64,
    expectedModelSizeBytes: Int64 = ParakeetModelInstaller.expectedModelSizeBytes
  ) throws {
    let requiredBytes = expectedModelSizeBytes * 2
    guard availableBytes >= requiredBytes else {
      throw ParakeetModelInstallError.insufficientDiskSpace(
        requiredBytes: requiredBytes,
        availableBytes: availableBytes
      )
    }
  }

  private func downloadAndInstallModel() async throws -> ParakeetInstalledModel {
    let modelsRoot =
      applicationSupportDirectory
      .appendingPathComponent(Self.modelsRootComponent, isDirectory: true)
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
      fileMissing: { ParakeetModelInstallError.fileMissingAfterDownload($0) },
      checksumMismatch: {
        ParakeetModelInstallError.checksumMismatch(relativePath: $0, expected: $1, actual: $2)
      },
      onProgress: { completedBytes in
        self.transition(
          to: .downloading(
            ParakeetModelDownloadProgress(
              fractionComplete: totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0,
              bytesReceived: completedBytes,
              totalBytes: totalBytes
            )))
      }
    )

    return ParakeetInstalledModel(
      name: Self.modelName,
      repository: Self.repository,
      revision: Self.sourceRevision,
      files: staged.files.map {
        ParakeetInstalledModelFile(
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

  private func transition(to newState: ParakeetModelInstallState) {
    state = newState
    stateStorage.saveState(newState)
  }
}

func parakeetModelDownloadFailure(for error: Error) -> ParakeetModelInstallFailure {
  if case .checksumMismatch = error as? ParakeetModelInstallError {
    return ParakeetModelInstallFailure(
      kind: .checksum,
      userSafeReason:
        String(
          localized:
            "The downloaded Parakeet model failed its integrity check and was discarded. Try downloading again."
        ),
      isRetryable: true
    )
  }

  if isParakeetDiskFull(error) {
    return ParakeetModelInstallFailure(
      kind: .disk,
      userSafeReason:
        String(
          localized:
            "There isn't enough device storage to install the Parakeet model. Free storage and try again."
        ),
      isRetryable: true
    )
  }

  if error is CancellationError || error as? ParakeetModelInstallError == .cancelled {
    return ParakeetModelInstallFailure(
      kind: .cancelled,
      userSafeReason: String(localized: "The Parakeet model download was cancelled."),
      isRetryable: true
    )
  }

  if error is URLError {
    return ParakeetModelInstallFailure(
      kind: .network,
      userSafeReason:
        String(
          localized:
            "Couldn't download the Parakeet model because the network request failed. Check your connection and try again."
        ),
      isRetryable: true
    )
  }

  let nsError = error as NSError
  if nsError.domain == NSURLErrorDomain {
    return ParakeetModelInstallFailure(
      kind: .network,
      userSafeReason:
        String(
          localized:
            "Couldn't download the Parakeet model because the network request failed. Check your connection and try again."
        ),
      isRetryable: true
    )
  }

  return ParakeetModelInstallFailure(
    kind: .unknown,
    userSafeReason:
      String(localized: "Couldn't install the Parakeet model on this device."),
    isRetryable: false
  )
}

func parakeetModelDeleteFailure(for error: Error) -> ParakeetModelInstallFailure {
  ParakeetModelInstallFailure(
    kind: .disk,
    userSafeReason:
      String(
        localized:
          "Couldn't delete the Parakeet model from the device. The device reported a storage or file-access error. Try again later."
      ),
    isRetryable: false
  )
}

private func isParakeetDiskFull(_ error: Error) -> Bool {
  if case .insufficientDiskSpace = error as? ParakeetModelInstallError {
    return true
  }
  return isModelInstallDiskFullNSError(error)
}
