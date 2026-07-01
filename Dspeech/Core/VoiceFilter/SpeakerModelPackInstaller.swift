import CryptoKit
import FluidAudio
import Foundation

enum ModelPackInstallError: Error, Equatable {
  case filesMissingAfterDownload
  case cancelled
  case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
  case integrityExpectedFileMissing(String)
  case integrityUnexpectedFile(String)
  case integrityChecksumMismatch(relativePath: String, expectedSHA256: String, actualSHA256: String)
  case integrityFileUnreadable(String)
  case integrityManifestEmpty

  var isIntegrityFailure: Bool {
    switch self {
    case .integrityExpectedFileMissing,
      .integrityUnexpectedFile,
      .integrityChecksumMismatch,
      .integrityFileUnreadable,
      .integrityManifestEmpty:
      return true
    case .filesMissingAfterDownload, .cancelled, .insufficientDiskSpace:
      return false
    }
  }
}

struct SpeakerModelPackInstaller: Sendable {
  struct ExpectedModelFile: Equatable, Sendable {
    let relativePath: String
    let sha256: String
    let sizeBytes: Int64

    init(relativePath: String, sha256: String, sizeBytes: Int64 = 0) {
      self.relativePath = relativePath
      self.sha256 = sha256
      self.sizeBytes = sizeBytes
    }
  }

  struct VerifiedModelPack: Equatable, Sendable {
    let checksumSHA256: String
    let sizeBytes: Int64
  }

  static let packIdentifier = "fluidaudio-wespeaker-v2"
  static let packVersion = "0.14.7"
  static let embeddingDimension = FluidAudioSpeakerIdentifier.weSpeakerEmbeddingDimension
  static let source = "FluidInference/speaker-diarization-coreml"
  static let sourceRevision = "1ed7a662fdc7109e36d822db793ee6eebdaf8594"
  static let registryBaseURLOverrideKey = "DspeechModelRegistryBaseURL"

  private let voiceFilterStorage: any VoiceFilterStorage
  private let availableCapacityProvider: @Sendable (URL) throws -> Int64

  init(
    voiceFilterStorage: any VoiceFilterStorage = UserDefaultsVoiceFilterStorage(),
    availableCapacityProvider: @escaping @Sendable (URL) throws -> Int64 =
      { try Self.availableCapacity(at: $0) }
  ) {
    self.voiceFilterStorage = voiceFilterStorage
    self.availableCapacityProvider = availableCapacityProvider
  }

  // why: ADR 0007/0008 — the model-weight source must be overridable to a mirror under our
  // own control without a Swift change. An Info.plist override (DspeechModelRegistryBaseURL)
  // wins; when absent we set nothing, so FluidAudio's own resolution
  // (REGISTRY_URL / MODEL_REGISTRY_URL env → HuggingFace) applies untouched.
  static func registryBaseURLOverride(infoDictionary: [String: Any]?) -> String? {
    guard let raw = infoDictionary?[registryBaseURLOverrideKey] as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func registryBaseURLOverride(bundle: Bundle = .main) -> String? {
    registryBaseURLOverride(infoDictionary: bundle.infoDictionary)
  }

  // why: the recorded install source must include the immutable revision so support/debug
  // reports can distinguish a pinned pack from a mutable HuggingFace `main` download.
  static func resolvedRegistrySource(infoDictionary: [String: Any]?) -> String {
    "\(registryBaseURL(infoDictionary: infoDictionary))/\(source)/resolve/\(sourceRevision)"
  }

  static func resolvedRegistrySource(bundle: Bundle = .main) -> String {
    resolvedRegistrySource(infoDictionary: bundle.infoDictionary)
  }

  static func pinnedDownloadURL(
    relativePath: String,
    infoDictionary: [String: Any]? = Bundle.main.infoDictionary
  ) throws -> URL {
    let encodedPath =
      relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
    let urlString =
      "\(registryBaseURL(infoDictionary: infoDictionary))/\(source)/resolve/\(sourceRevision)/\(encodedPath)"
    guard let url = URL(string: urlString) else {
      throw ModelRegistry.Error.invalidURL(urlString)
    }
    return url
  }

  // why: NSLock guards the mutable holder/waiter state, and continuations are resumed outside
  // the critical section so cancellation and release cannot race into a double-resume.
  private final class RegistryBaseURLGate: @unchecked Sendable {
    private struct Waiter {
      let id: UUID
      let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var isLocked = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
      let id = UUID()
      try Task.checkCancellation()
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, any Error>) in
          lock.lock()
          if Task.isCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
          } else if isLocked {
            waiters.append(Waiter(id: id, continuation: continuation))
            lock.unlock()
          } else {
            isLocked = true
            lock.unlock()
            continuation.resume()
          }
        }
      } onCancel: {
        cancelWaiter(id)
      }
    }

    private func cancelWaiter(_ id: UUID) {
      let continuation: CheckedContinuation<Void, any Error>?
      lock.lock()
      if let index = waiters.firstIndex(where: { $0.id == id }) {
        continuation = waiters.remove(at: index).continuation
      } else {
        continuation = nil
      }
      lock.unlock()
      continuation?.resume(throwing: CancellationError())
    }

    func release() {
      let continuation: CheckedContinuation<Void, any Error>?
      lock.lock()
      if waiters.isEmpty {
        isLocked = false
        continuation = nil
      } else {
        continuation = waiters.removeFirst().continuation
      }
      lock.unlock()
      continuation?.resume()
    }
  }

  private static func registryBaseURL(infoDictionary: [String: Any]?) -> String {
    withoutTrailingSlash(
      registryBaseURLOverride(infoDictionary: infoDictionary) ?? ModelRegistry.baseURL
    )
  }

  private static func withoutTrailingSlash(_ raw: String) -> String {
    var value = raw
    while value.hasSuffix("/") {
      value.removeLast()
    }
    return value
  }

  private static let registryBaseURLGate = RegistryBaseURLGate()

  @discardableResult
  private static func applyConfiguredRegistryBaseURL(infoDictionary: [String: Any]?) -> String {
    if let override = registryBaseURLOverride(infoDictionary: infoDictionary) {
      ModelRegistry.baseURL = withoutTrailingSlash(override)
    }
    return ModelRegistry.baseURL
  }

  static func withConfiguredRegistryBaseURL<T>(
    infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
    operation: @Sendable () async throws -> T
  ) async throws -> T {
    try await registryBaseURLGate.acquire()
    let original = ModelRegistry.baseURL
    let hasOverride = registryBaseURLOverride(infoDictionary: infoDictionary) != nil
    _ = applyConfiguredRegistryBaseURL(infoDictionary: infoDictionary)
    defer {
      if hasOverride {
        ModelRegistry.baseURL = original
      }
      registryBaseURLGate.release()
    }
    try Task.checkCancellation()
    return try await operation()
  }

  static let segmentationFile = FluidAudioBackendBuilder.segmentationModelFileName
  static let embeddingFile = FluidAudioBackendBuilder.embeddingModelFileName
  static let expectedModelFileManifest: [ExpectedModelFile] = [
    ExpectedModelFile(
      relativePath: "pyannote_segmentation.mlmodelc/analytics/coremldata.bin",
      sha256: "b379db0541b35344a34bb7540783ae704c11599bbed5aa8bbbda11c20ad215ee",
      sizeBytes: 243
    ),
    ExpectedModelFile(
      relativePath: "pyannote_segmentation.mlmodelc/coremldata.bin",
      sha256: "4a450ea1b053b9eb7eef0cab6971018076600840c7e246d064e7c5387f456c98",
      sizeBytes: 316
    ),
    ExpectedModelFile(
      relativePath: "pyannote_segmentation.mlmodelc/metadata.json",
      sha256: "44e1fa36d6abafacf688beccad99f7569394248d8bb41545829997c67668c08c",
      sizeBytes: 1_763
    ),
    ExpectedModelFile(
      relativePath: "pyannote_segmentation.mlmodelc/model.mil",
      sha256: "97f2dec6f83e80bf4247b98e13c2dde19f92c05820ef08068bbf554488d70bdd",
      sizeBytes: 29_490
    ),
    ExpectedModelFile(
      relativePath: "pyannote_segmentation.mlmodelc/weights/weight.bin",
      sha256: "0266f4ad4d843ecf31ef9220ad6b80616b3ec64a4404b64f3ea0371554e236ec",
      sizeBytes: 5_734_720
    ),
    ExpectedModelFile(
      relativePath: "wespeaker_v2.mlmodelc/analytics/coremldata.bin",
      sha256: "d2b1fcde6121aea3ff0e14c1dc50d09dacb0314a2e89156353c31804230a422f",
      sizeBytes: 243
    ),
    ExpectedModelFile(
      relativePath: "wespeaker_v2.mlmodelc/coremldata.bin",
      sha256: "6feb2472a71fa9d8a84020c85206138a4f6261c565c9884bf518d59dd5838da7",
      sizeBytes: 359
    ),
    ExpectedModelFile(
      relativePath: "wespeaker_v2.mlmodelc/metadata.json",
      sha256: "ddc4858b4051254098015cd0b97080149839d697faf7b036f933190e70b26758",
      sizeBytes: 2_738
    ),
    ExpectedModelFile(
      relativePath: "wespeaker_v2.mlmodelc/model.mil",
      sha256: "2850f775d6ba659f01f616fed77ce6a45a25de3eb7e4bf3a4b07b658be4e13dd",
      sizeBytes: 706_900
    ),
    ExpectedModelFile(
      relativePath: "wespeaker_v2.mlmodelc/weights/weight.bin",
      sha256: "34004f6798d35cad7071e2fdc67e63faaa782f53697e1cb49bcb452cf81ae151",
      sizeBytes: 7_243_904
    ),
  ]

  static let expectedPackSizeBytes: Int64 = expectedModelFileManifest.reduce(0) {
    $0 + $1.sizeBytes
  }

  func install(
    progress: @escaping @Sendable (ModelPackAcquisition) -> Void
  ) async throws -> InstalledModelPack {
    DspeechLog.modelPack.info(
      "model pack install started identifier=\(Self.packIdentifier, privacy: .public) version=\(Self.packVersion, privacy: .public)"
    )
    let cacheRoot = Self.modelCacheRoot()
    let installSource = Self.resolvedRegistrySource()
    do {
      try await Self.downloadModelPack(
        to: cacheRoot,
        progress: progress,
        availableCapacityProvider: availableCapacityProvider
      )
      do {
        let pack = try Self.installedPackAfterVerification(source: installSource)
        DspeechLog.modelPack.info(
          "model pack install succeeded identifier=\(pack.identifier, privacy: .public) version=\(pack.version, privacy: .public) bytes=\(pack.sizeBytes, privacy: .public)"
        )
        return pack
      } catch let error as ModelPackInstallError {
        guard error.isIntegrityFailure else { throw error }
        DspeechLog.modelPack.error(
          "model pack verification failed integrity=true error=\(String(describing: error), privacy: .public)"
        )
        if let modelDir = Self.locateModelDirectory() {
          DspeechLog.modelPack.info("model pack removing failed integrity directory")
          try Self.removeModelDirectory(modelDir)
        }
        DspeechLog.modelPack.info("model pack retrying download after integrity failure")
        try await Self.downloadModelPack(
          to: cacheRoot,
          progress: progress,
          availableCapacityProvider: availableCapacityProvider
        )
        let pack = try Self.installedPackAfterVerification(source: installSource)
        DspeechLog.modelPack.info(
          "model pack install succeeded after retry identifier=\(pack.identifier, privacy: .public) version=\(pack.version, privacy: .public) bytes=\(pack.sizeBytes, privacy: .public)"
        )
        return pack
      }
    } catch {
      DspeechLog.modelPack.error("model pack install failed error=\(error.localizedDescription)")
      throw error
    }
  }

  func uninstall(_ pack: InstalledModelPack) throws {
    DspeechLog.modelPack.info(
      "model pack uninstall requested identifier=\(pack.identifier, privacy: .public) version=\(pack.version, privacy: .public)"
    )
    try Self.uninstall(pack)
    voiceFilterStorage.deleteAllProfiles()
    DspeechLog.modelPack.info(
      "model pack uninstall succeeded identifier=\(pack.identifier, privacy: .public) version=\(pack.version, privacy: .public)"
    )
  }

  static func uninstall(
    _ pack: InstalledModelPack,
    fileManager: FileManager = .default
  ) throws {
    if let localModelPath = pack.localModelPath, !localModelPath.isEmpty {
      let modelDir = URL(fileURLWithPath: localModelPath, isDirectory: true)
      if fileManager.fileExists(atPath: modelDir.path) {
        DspeechLog.modelPack.info("model pack uninstall removing installed directory")
        try removeModelDirectory(modelDir, fileManager: fileManager)
      }
      return
    }

    if let modelDir = Self.locateModelDirectory(fileManager: fileManager) {
      DspeechLog.modelPack.info("model pack uninstall removing located directory")
      try removeModelDirectory(modelDir, fileManager: fileManager)
    }
  }

  static func installedPackAfterVerification(
    source: String = Self.resolvedRegistrySource()
  ) throws -> InstalledModelPack {
    DspeechLog.modelPack.info("model pack verification started")
    guard let modelDir = Self.locateModelDirectory() else {
      DspeechLog.modelPack.error("model pack verification failed reason=files-missing")
      throw ModelPackInstallError.filesMissingAfterDownload
    }
    let verified = try Self.verifyModelPack(at: modelDir)
    DspeechLog.modelPack.info(
      "model pack verification succeeded bytes=\(verified.sizeBytes, privacy: .public)"
    )

    return InstalledModelPack(
      identifier: Self.packIdentifier,
      version: Self.packVersion,
      embeddingDimension: Self.embeddingDimension,
      checksumSHA256: verified.checksumSHA256,
      source: source,
      sizeBytes: verified.sizeBytes,
      installedAt: Date(),
      localModelPath: modelDir.path
    )
  }

  static func locateModelDirectory(
    in root: URL = fluidAudioRoot(),
    cacheRoot: URL = modelCacheRoot(),
    fileManager: FileManager = .default
  ) -> URL? {
    let directCandidates = [
      cacheRoot.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true),
      cacheRoot.appendingPathComponent("speaker-diarization-coreml", isDirectory: true),
    ]
    for direct in directCandidates where hasBothModels(at: direct, fileManager: fileManager) {
      DspeechLog.modelPack.debug("model pack directory located strategy=direct")
      return direct
    }

    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else { return nil }

    for case let url as URL in enumerator {
      let isDirectory: Bool
      do {
        isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
      } catch {
        continue
      }
      guard isDirectory else { continue }
      if hasBothModels(at: url, fileManager: fileManager) {
        DspeechLog.modelPack.debug("model pack directory located strategy=enumerated")
        return url
      }
    }
    return nil
  }

  static func modelCacheRoot() -> URL {
    DiarizerModels.defaultModelsDirectory().deletingLastPathComponent()
  }

  static func verifyModelPack(
    at modelDirectory: URL,
    manifest: [ExpectedModelFile] = expectedModelFileManifest,
    fileManager: FileManager = .default
  ) throws -> VerifiedModelPack {
    DspeechLog.modelPack.info(
      "model pack integrity verification started manifestFiles=\(manifest.count, privacy: .public)"
    )
    guard !manifest.isEmpty else {
      DspeechLog.modelPack.error("model pack integrity verification failed reason=empty-manifest")
      throw ModelPackInstallError.integrityManifestEmpty
    }
    let normalizedManifest = manifest.sorted { $0.relativePath < $1.relativePath }
    let expectedPaths = Set(normalizedManifest.map(\.relativePath))
    let actualPaths = try regularModelFiles(at: modelDirectory, fileManager: fileManager)

    for relativePath in expectedPaths.subtracting(actualPaths).sorted() {
      DspeechLog.modelPack.error(
        "model pack integrity verification failed reason=expected-file-missing"
      )
      throw ModelPackInstallError.integrityExpectedFileMissing(relativePath)
    }
    for relativePath in actualPaths.subtracting(expectedPaths).sorted() {
      DspeechLog.modelPack.error("model pack integrity verification failed reason=unexpected-file")
      throw ModelPackInstallError.integrityUnexpectedFile(relativePath)
    }

    var packHasher = SHA256()
    var sizeBytes: Int64 = 0
    for entry in normalizedManifest {
      let fileURL = modelDirectory.appendingPathComponent(entry.relativePath, isDirectory: false)
      let data: Data
      do {
        data = try Data(contentsOf: fileURL)
      } catch {
        DspeechLog.modelPack.error(
          "model pack integrity verification failed reason=file-unreadable"
        )
        throw ModelPackInstallError.integrityFileUnreadable(entry.relativePath)
      }

      let digest = SHA256.hash(data: data)
      let actualSHA256 = hexDigest(digest)
      guard actualSHA256 == entry.sha256 else {
        DspeechLog.modelPack.error(
          "model pack integrity verification failed reason=checksum-mismatch"
        )
        throw ModelPackInstallError.integrityChecksumMismatch(
          relativePath: entry.relativePath,
          expectedSHA256: entry.sha256,
          actualSHA256: actualSHA256
        )
      }

      packHasher.update(data: digestData(digest))
      sizeBytes += Int64(data.count)
    }

    DspeechLog.modelPack.info(
      "model pack integrity verification succeeded files=\(normalizedManifest.count, privacy: .public) bytes=\(sizeBytes, privacy: .public)"
    )
    return VerifiedModelPack(
      checksumSHA256: hexDigest(packHasher.finalize()),
      sizeBytes: sizeBytes
    )
  }

  static func fluidAudioRoot() -> URL {
    ApplicationSupport.directoryOrTrap()
      .appendingPathComponent("FluidAudio", isDirectory: true)
  }

  private static func hasBothModels(at directory: URL, fileManager: FileManager) -> Bool {
    fileManager.fileExists(atPath: directory.appendingPathComponent(segmentationFile).path)
      && fileManager.fileExists(atPath: directory.appendingPathComponent(embeddingFile).path)
  }

  private static func downloadModelPack(
    to cacheRoot: URL,
    progress: @escaping @Sendable (ModelPackAcquisition) -> Void,
    availableCapacityProvider: @Sendable (URL) throws -> Int64
  ) async throws {
    DspeechLog.modelPack.info(
      "model pack download started source=\(Self.resolvedRegistrySource(), privacy: .public)"
    )
    do {
      try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
      let availableBytes = try availableCapacityProvider(cacheRoot)
      try preflightSufficientFreeSpace(availableBytes: availableBytes)
      try await withConfiguredRegistryBaseURL {
        try await downloadPinnedModelFiles(to: cacheRoot, progress: progress)
      }
      DspeechLog.modelPack.info("model pack download finished")
    } catch {
      DspeechLog.modelPack.error("model pack download failed error=\(error.localizedDescription)")
      throw error
    }
  }

  static func preflightSufficientFreeSpace(
    availableBytes: Int64,
    expectedPackSizeBytes: Int64 = Self.expectedPackSizeBytes
  ) throws {
    let requiredBytes = expectedPackSizeBytes * 2
    guard availableBytes >= requiredBytes else {
      throw ModelPackInstallError.insufficientDiskSpace(
        requiredBytes: requiredBytes,
        availableBytes: availableBytes
      )
    }
  }

  private static func availableCapacity(at url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
    guard let freeSize = attributes[.systemFreeSize] as? NSNumber else {
      return 0
    }
    return freeSize.int64Value
  }

  private static func downloadPinnedModelFiles(
    to cacheRoot: URL,
    progress: @escaping @Sendable (ModelPackAcquisition) -> Void
  ) async throws {
    let repoPath = cacheRoot.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
    var completedBytes: Int64 = 0
    progress(
      ModelPackAcquisition(
        phase: .downloading,
        fractionComplete: 0,
        bytesReceived: completedBytes,
        totalBytes: expectedPackSizeBytes
      ))

    for entry in expectedModelFileManifest {
      try Task.checkCancellation()
      let destination = repoPath.appendingPathComponent(entry.relativePath, isDirectory: false)
      if FileManager.default.fileExists(atPath: destination.path) {
        completedBytes += entry.sizeBytes
        progressDownload(completedBytes: completedBytes, progress: progress)
        continue
      }

      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let request = URLRequest(url: try pinnedDownloadURL(relativePath: entry.relativePath))
      let (temporaryURL, response) = try await URLSession.shared.download(for: request)
      guard let httpResponse = response as? HTTPURLResponse,
        (200..<300).contains(httpResponse.statusCode)
      else {
        throw URLError(.badServerResponse)
      }
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.moveItem(at: temporaryURL, to: destination)
      completedBytes += entry.sizeBytes
      progressDownload(completedBytes: completedBytes, progress: progress)
    }
    progress(
      ModelPackAcquisition(
        phase: .importing,
        fractionComplete: 1,
        bytesReceived: expectedPackSizeBytes,
        totalBytes: expectedPackSizeBytes
      ))
  }

  private static func progressDownload(
    completedBytes: Int64,
    progress: @escaping @Sendable (ModelPackAcquisition) -> Void
  ) {
    let fraction = Double(completedBytes) / Double(expectedPackSizeBytes)
    progress(
      ModelPackAcquisition(
        phase: .downloading,
        fractionComplete: min(max(fraction, 0), 1),
        bytesReceived: completedBytes,
        totalBytes: expectedPackSizeBytes
      ))
  }

  private static func removeModelDirectory(_ modelDir: URL, fileManager: FileManager = .default)
    throws
  {
    DspeechLog.modelPack.info("model pack directory removal requested")
    try fileManager.removeItem(at: modelDir)
    DspeechLog.modelPack.info("model pack directory removal succeeded")
  }

  private static func regularModelFiles(at modelDirectory: URL, fileManager: FileManager) throws
    -> Set<String>
  {
    var files = Set<String>()
    for directoryName in [segmentationFile, embeddingFile] {
      let directory = modelDirectory.appendingPathComponent(directoryName, isDirectory: true)
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        DspeechLog.modelPack.error(
          "model pack integrity verification failed reason=model-dir-missing"
        )
        throw ModelPackInstallError.integrityExpectedFileMissing(directoryName)
      }
      guard
        let enumerator = fileManager.enumerator(
          at: directory,
          includingPropertiesForKeys: [.isRegularFileKey]
        )
      else {
        DspeechLog.modelPack.error(
          "model pack integrity verification failed reason=model-dir-unreadable"
        )
        throw ModelPackInstallError.integrityExpectedFileMissing(directoryName)
      }
      for case let fileURL as URL in enumerator {
        let relativePath = relativePath(from: modelDirectory, to: fileURL)
        do {
          let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
          if values.isRegularFile == true {
            files.insert(relativePath)
          }
        } catch {
          DspeechLog.modelPack.error(
            "model pack integrity verification failed reason=file-unreadable"
          )
          throw ModelPackInstallError.integrityFileUnreadable(relativePath)
        }
      }
    }
    return files
  }

  private static func relativePath(from root: URL, to fileURL: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let filePath = fileURL.standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard filePath.hasPrefix(prefix) else { return fileURL.lastPathComponent }
    return String(filePath.dropFirst(prefix.count))
  }

  private static func digestData(_ digest: SHA256.Digest) -> Data {
    digest.withUnsafeBytes { Data($0) }
  }

  private static func hexDigest(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}
