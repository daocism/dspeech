import CryptoKit
import Foundation
import Observation

enum WhisperKitModelInstallError: Error, Equatable {
  case cancelled
  case invalidURL(String)
  case fileMissingAfterDownload(String)
  case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
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
      applicationSupportDirectory ?? Self.defaultApplicationSupportDirectory()
  }

  func loadState() -> WhisperKitModelInstallState {
    guard let data = defaults.data(forKey: Self.stateKey) else {
      return .absent
    }
    do {
      let decoded = try JSONDecoder().decode(WhisperKitModelInstallState.self, from: data)
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

  func saveState(_ state: WhisperKitModelInstallState) {
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

  private static let corruptPersistedStateFailure = WhisperKitModelInstallFailure(
    kind: .corruptState,
    userSafeReason:
      String(
        localized:
          "The saved WhisperKit model state is corrupted. Continue with Apple Speech and re-download the model if needed."
      ),
    isRetryable: false
  )

  private static func defaultApplicationSupportDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
  }

  private static func resolvedModelPaths(
    in state: WhisperKitModelInstallState,
    applicationSupportDirectory: URL
  ) -> WhisperKitModelInstallState {
    switch state {
    case .installed(let model):
      return .installed(
        model.replacingLocalModelPath(
          resolvedLocalModelPath(
            model.localModelPath,
            applicationSupportDirectory: applicationSupportDirectory
          )))
    case .absent, .downloading, .failed:
      return state
    }
  }

  private static func persistedModelPaths(
    in state: WhisperKitModelInstallState,
    applicationSupportDirectory: URL
  ) -> WhisperKitModelInstallState {
    switch state {
    case .installed(let model):
      return .installed(
        model.replacingLocalModelPath(
          persistedLocalModelPath(
            model.localModelPath,
            applicationSupportDirectory: applicationSupportDirectory
          )))
    case .absent, .downloading, .failed:
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

protocol WhisperKitModelFileDownloading: Sendable {
  func download(from sourceURL: URL, to destinationURL: URL) async throws
}

struct URLSessionWhisperKitModelFileDownloader: WhisperKitModelFileDownloading {
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
final class WhisperKitModelInstaller {
  struct ExpectedModelFile: Equatable, Sendable {
    let relativePath: String
    let sizeBytes: Int64
  }

  nonisolated static let modelName = "large-v3-v20240930_626MB"
  nonisolated static let modelFolderName = "openai_whisper-large-v3-v20240930_626MB"
  nonisolated static let repository = "argmaxinc/whisperkit-coreml"
  // why: supply-chain policy forbids downloading mutable Hugging Face main; this is main as resolved on 2026-06-12.
  nonisolated static let pinnedRevision = "97a5bf9bbc74c7d9c12c755d04dea59e672e3808"
  nonisolated static let expectedModelFiles: [ExpectedModelFile] = [
    ExpectedModelFile(
      relativePath: "AudioEncoder.mlmodelc/analytics/coremldata.bin",
      sizeBytes: 243
    ),
    ExpectedModelFile(relativePath: "AudioEncoder.mlmodelc/coremldata.bin", sizeBytes: 348),
    ExpectedModelFile(relativePath: "AudioEncoder.mlmodelc/metadata.json", sizeBytes: 1_922),
    ExpectedModelFile(relativePath: "AudioEncoder.mlmodelc/model.mil", sizeBytes: 934_263),
    ExpectedModelFile(
      relativePath: "AudioEncoder.mlmodelc/weights/weight.bin",
      sizeBytes: 421_968_768
    ),
    ExpectedModelFile(
      relativePath: "MelSpectrogram.mlmodelc/analytics/coremldata.bin",
      sizeBytes: 243
    ),
    ExpectedModelFile(relativePath: "MelSpectrogram.mlmodelc/coremldata.bin", sizeBytes: 329),
    ExpectedModelFile(relativePath: "MelSpectrogram.mlmodelc/metadata.json", sizeBytes: 1_850),
    ExpectedModelFile(relativePath: "MelSpectrogram.mlmodelc/model.mil", sizeBytes: 10_143),
    ExpectedModelFile(
      relativePath: "MelSpectrogram.mlmodelc/weights/weight.bin",
      sizeBytes: 373_376
    ),
    ExpectedModelFile(
      relativePath: "TextDecoder.mlmodelc/analytics/coremldata.bin",
      sizeBytes: 243
    ),
    ExpectedModelFile(relativePath: "TextDecoder.mlmodelc/coremldata.bin", sizeBytes: 633),
    ExpectedModelFile(relativePath: "TextDecoder.mlmodelc/metadata.json", sizeBytes: 4_924),
    ExpectedModelFile(relativePath: "TextDecoder.mlmodelc/model.mil", sizeBytes: 217_177),
    ExpectedModelFile(
      relativePath: "TextDecoder.mlmodelc/weights/weight.bin",
      sizeBytes: 203_199_860
    ),
    ExpectedModelFile(relativePath: "config.json", sizeBytes: 1_149),
    ExpectedModelFile(relativePath: "generation_config.json", sizeBytes: 2_767),
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

  init(
    stateStorage: any WhisperKitModelStateStorage = UserDefaultsWhisperKitModelStateStorage(),
    fileDownloader: any WhisperKitModelFileDownloading = URLSessionWhisperKitModelFileDownloader(),
    applicationSupportDirectory: URL? = nil,
    availableCapacityProvider: @escaping @Sendable (URL) throws -> Int64 = {
      try WhisperKitModelInstaller.availableCapacity(at: $0)
    },
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.stateStorage = stateStorage
    self.fileDownloader = fileDownloader
    self.applicationSupportDirectory =
      applicationSupportDirectory ?? Self.defaultApplicationSupportDirectory()
    self.availableCapacityProvider = availableCapacityProvider
    self.now = now
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
      transition(to: .failed(whisperKitModelDownloadFailure(for: error)))
    }
  }

  func deleteInstalledModel() async {
    do {
      if let installedModelFolderURL {
        try Self.removeIfPresent(installedModelFolderURL)
      }
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
    let requiredBytes = expectedModelSizeBytes * 2
    guard availableBytes >= requiredBytes else {
      throw WhisperKitModelInstallError.insufficientDiskSpace(
        requiredBytes: requiredBytes,
        availableBytes: availableBytes
      )
    }
  }

  private func downloadAndInstallModel() async throws -> WhisperKitInstalledModel {
    let modelsRoot =
      applicationSupportDirectory
      .appendingPathComponent("WhisperKit/Models", isDirectory: true)
    try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    try Self.excludeFromBackup(modelsRoot)
    try Self.preflightSufficientFreeSpace(
      availableBytes: availableCapacityProvider(modelsRoot)
    )

    let stagingRoot = modelsRoot.appendingPathComponent(
      ".\(Self.modelFolderName).staging-\(UUID().uuidString)",
      isDirectory: true
    )
    let stagingModelFolder = stagingRoot.appendingPathComponent(
      Self.modelFolderName,
      isDirectory: true
    )
    let finalModelFolder = modelsRoot.appendingPathComponent(
      Self.modelFolderName, isDirectory: true)
    try Self.removeIfPresent(stagingRoot)
    try FileManager.default.createDirectory(
      at: stagingModelFolder, withIntermediateDirectories: true)
    try Self.excludeFromBackup(stagingRoot)

    do {
      let files = try await downloadFiles(to: stagingModelFolder)
      let sizeBytes = files.reduce(Int64(0)) { $0 + $1.sizeBytes }
      try Self.removeIfPresent(finalModelFolder)
      try FileManager.default.moveItem(at: stagingModelFolder, to: finalModelFolder)
      try Self.removeIfPresent(stagingRoot)
      try Self.excludeFromBackup(finalModelFolder)
      return WhisperKitInstalledModel(
        name: Self.modelName,
        repository: Self.repository,
        revision: Self.pinnedRevision,
        files: files,
        sizeBytes: sizeBytes,
        installedAt: now(),
        localModelPath: finalModelFolder.path
      )
    } catch {
      try? Self.removeIfPresent(stagingRoot)
      throw error
    }
  }

  private func downloadFiles(to stagingModelFolder: URL) async throws
    -> [WhisperKitInstalledModelFile]
  {
    var completedBytes: Int64 = 0
    var installedFiles: [WhisperKitInstalledModelFile] = []
    transition(
      to: .downloading(
        WhisperKitModelDownloadProgress(
          fractionComplete: 0,
          bytesReceived: completedBytes,
          totalBytes: Self.expectedModelSizeBytes
        )))

    for expectedFile in Self.expectedModelFiles {
      try Task.checkCancellation()
      let destination = stagingModelFolder.appendingPathComponent(
        expectedFile.relativePath,
        isDirectory: false
      )
      try await fileDownloader.download(
        from: Self.pinnedDownloadURL(relativePath: expectedFile.relativePath),
        to: destination
      )
      guard FileManager.default.fileExists(atPath: destination.path) else {
        throw WhisperKitModelInstallError.fileMissingAfterDownload(expectedFile.relativePath)
      }
      let data = try Data(contentsOf: destination)
      let file = WhisperKitInstalledModelFile(
        relativePath: expectedFile.relativePath,
        sha256: Self.hexDigest(SHA256.hash(data: data)),
        sizeBytes: Int64(data.count)
      )
      installedFiles.append(file)
      completedBytes += expectedFile.sizeBytes
      transition(
        to: .downloading(
          WhisperKitModelDownloadProgress(
            fractionComplete: Double(completedBytes) / Double(Self.expectedModelSizeBytes),
            bytesReceived: completedBytes,
            totalBytes: Self.expectedModelSizeBytes
          )))
    }
    return installedFiles.sorted { $0.relativePath < $1.relativePath }
  }

  private func transition(to newState: WhisperKitModelInstallState) {
    state = newState
    stateStorage.saveState(newState)
  }

  private static func defaultApplicationSupportDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
  }

  private nonisolated static func availableCapacity(at url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
    guard let freeSize = attributes[.systemFreeSize] as? NSNumber else {
      return 0
    }
    return freeSize.int64Value
  }

  private static func removeIfPresent(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  private static func excludeFromBackup(_ url: URL) throws {
    var mutableURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try mutableURL.setResourceValues(values)
  }

  private static func hexDigest(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}

func whisperKitModelDownloadFailure(for error: Error) -> WhisperKitModelInstallFailure {
  if isWhisperKitDiskFull(error) {
    return WhisperKitModelInstallFailure(
      kind: .disk,
      userSafeReason:
        String(
          localized:
            "There isn't enough device storage to install the WhisperKit model. Free storage and try again."
        ),
      isRetryable: true
    )
  }

  if error is CancellationError || error as? WhisperKitModelInstallError == .cancelled {
    return WhisperKitModelInstallFailure(
      kind: .cancelled,
      userSafeReason: String(localized: "The WhisperKit model download was cancelled."),
      isRetryable: true
    )
  }

  if error is URLError {
    return WhisperKitModelInstallFailure(
      kind: .network,
      userSafeReason:
        String(
          localized:
            "Couldn't download the WhisperKit model because the network request failed. Check your connection and try again."
        ),
      isRetryable: true
    )
  }

  let nsError = error as NSError
  if nsError.domain == NSURLErrorDomain {
    return WhisperKitModelInstallFailure(
      kind: .network,
      userSafeReason:
        String(
          localized:
            "Couldn't download the WhisperKit model because the network request failed. Check your connection and try again."
        ),
      isRetryable: true
    )
  }

  return WhisperKitModelInstallFailure(
    kind: .unknown,
    userSafeReason:
      String(localized: "Couldn't install the WhisperKit model on this device."),
    isRetryable: false
  )
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
  let nsError = error as NSError
  if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
    return true
  }
  if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(POSIXErrorCode.ENOSPC.rawValue) {
    return true
  }
  if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
    return isWhisperKitDiskFull(underlying)
  }
  return false
}
