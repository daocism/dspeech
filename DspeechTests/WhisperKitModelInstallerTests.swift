import CryptoKit
import Foundation
import Testing

@testable import Dspeech

@MainActor
struct WhisperKitModelInstallerTests {
  @Test func productionModelPinsHuggingFaceRevisionAndFileList() throws {
    #expect(WhisperKitModelInstaller.modelName == "large-v3-v20240930_626MB")
    #expect(WhisperKitModelInstaller.modelFolderName == "openai_whisper-large-v3-v20240930_626MB")
    #expect(
      WhisperKitModelInstaller.pinnedRevision
        == "97a5bf9bbc74c7d9c12c755d04dea59e672e3808"
    )
    #expect(WhisperKitModelInstaller.expectedModelSizeBytes == 626_718_238)
    #expect(WhisperKitModelInstaller.expectedModelFiles.count == 17)
    // why: B4 — every shipped file must carry a 64-hex-char SHA-256 so the install path verifies
    // integrity (never fail-open). No placeholder/empty hashes.
    #expect(
      WhisperKitModelInstaller.expectedModelFiles.allSatisfy {
        $0.expectedSHA256.count == 64 && $0.expectedSHA256.allSatisfy { $0.isHexDigit }
      })
    #expect(
      try WhisperKitModelInstaller.pinnedDownloadURL(relativePath: "config.json").absoluteString
        == "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/97a5bf9bbc74c7d9c12c755d04dea59e672e3808/openai_whisper-large-v3-v20240930_626MB/config.json"
    )
  }

  @Test func installDownloadsPinnedFilesAndRecordsChecksumManifest() async throws {
    let appSupport = Self.makeApplicationSupportDirectory()
    defer { Self.remove(appSupport) }
    let (files, contents) = Self.fixtureManifest()
    let storage = InMemoryWhisperKitModelStateStorage()
    let downloader = FakeWhisperKitModelFileDownloader(contents: contents)
    let installer = WhisperKitModelInstaller(
      stateStorage: storage,
      fileDownloader: downloader,
      applicationSupportDirectory: appSupport,
      availableCapacityProvider: { _ in 1_000_000_000 },
      now: { Date(timeIntervalSince1970: 1_718_000_000) },
      expectedFiles: files
    )

    await installer.install()

    guard case .installed(let model) = installer.state else {
      Issue.record("expected installed state, got \(installer.state)")
      return
    }
    let folderURL = try #require(installer.installedModelFolderURL)
    #expect(folderURL.path.hasSuffix("WhisperKit/Models/openai_whisper-large-v3-v20240930_626MB"))
    #expect(FileManager.default.fileExists(atPath: folderURL.path))
    #expect(model.files.count == files.count)
    #expect(model.sizeBytes == contents.values.reduce(Int64(0)) { $0 + Int64($1.count) })
    #expect(model.revision == WhisperKitModelInstaller.pinnedRevision)
    for file in files {
      let recorded = try #require(model.files.first { $0.relativePath == file.relativePath })
      #expect(recorded.sha256.lowercased() == file.expectedSHA256.lowercased())
    }
    #expect(
      model.files.first { $0.relativePath == "config.json" }?.sha256
        == Self.sha256(Data("config".utf8)))
    #expect(
      downloader.downloadedRelativePaths
        == WhisperKitModelInstaller.expectedModelFiles.map(\.relativePath))
    #expect(storage.savedStates.contains { if case .downloading = $0 { true } else { false } })
    #expect(storage.state == .installed(model))
  }

  // why: B4 upgrade — a downloaded file whose bytes don't match the pinned SHA-256 must fail the
  // install (never fail-open, never load a tampered/corrupt CoreML bundle), leaving no model folder.
  @Test func checksumMismatchFailsInstallAndLeavesNoModelFolder() async {
    let appSupport = Self.makeApplicationSupportDirectory()
    defer { Self.remove(appSupport) }
    let storage = InMemoryWhisperKitModelStateStorage()
    // the REAL pinned manifest, but the downloader yields bytes that can't match any real hash
    let contents = Dictionary(
      uniqueKeysWithValues: WhisperKitModelInstaller.expectedModelFiles.map {
        ($0.relativePath, Data("corrupted-bytes".utf8))
      })
    let downloader = FakeWhisperKitModelFileDownloader(contents: contents)
    let installer = WhisperKitModelInstaller(
      stateStorage: storage,
      fileDownloader: downloader,
      applicationSupportDirectory: appSupport,
      availableCapacityProvider: { _ in WhisperKitModelInstaller.expectedModelSizeBytes * 2 }
    )

    await installer.install()

    guard case .failed(let failure) = installer.state else {
      Issue.record("expected failed state, got \(installer.state)")
      return
    }
    #expect(failure.kind == .checksum)
    #expect(installer.installedModelFolderURL == nil)
    let finalFolder = appSupport.appendingPathComponent(
      "WhisperKit/Models/openai_whisper-large-v3-v20240930_626MB")
    #expect(!FileManager.default.fileExists(atPath: finalFolder.path))
  }

  @Test func checksumMismatchMapsToChecksumFailureTaxonomy() {
    let failure = whisperKitModelDownloadFailure(
      for: WhisperKitModelInstallError.checksumMismatch(
        relativePath: "config.json", expected: "aaa", actual: "bbb"))
    #expect(failure.kind == .checksum)
    #expect(failure.isRetryable)
  }

  @Test func installedManifestPersistsRelativePathAndReloadsAbsolutePath() throws {
    let suiteName = "dspeech.tests.whisperkit.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let appSupport = Self.makeApplicationSupportDirectory()
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      Self.remove(appSupport)
    }
    let storage = UserDefaultsWhisperKitModelStateStorage(
      defaults: defaults,
      applicationSupportDirectory: appSupport
    )
    let absolutePath =
      appSupport
      .appendingPathComponent("WhisperKit/Models/openai_whisper-large-v3-v20240930_626MB")
      .path
    let model = Self.installedModel(localModelPath: absolutePath)

    storage.saveState(.installed(model))

    let data = try #require(defaults.data(forKey: UserDefaultsWhisperKitModelStateStorage.stateKey))
    guard
      case .installed(let persistedModel) = try JSONDecoder().decode(
        WhisperKitModelInstallState.self,
        from: data
      )
    else {
      Issue.record("expected raw persisted installed state")
      return
    }
    #expect(
      persistedModel.localModelPath
        == "WhisperKit/Models/openai_whisper-large-v3-v20240930_626MB"
    )
    #expect(storage.loadState() == .installed(model))
  }

  @Test func deleteInstalledModelRemovesFolderAndReturnsToAbsent() async throws {
    let appSupport = Self.makeApplicationSupportDirectory()
    defer { Self.remove(appSupport) }
    let (files, contents) = Self.fixtureManifest()
    let storage = InMemoryWhisperKitModelStateStorage()
    let downloader = FakeWhisperKitModelFileDownloader(contents: contents)
    let installer = WhisperKitModelInstaller(
      stateStorage: storage,
      fileDownloader: downloader,
      applicationSupportDirectory: appSupport,
      availableCapacityProvider: { _ in 1_000_000_000 },
      expectedFiles: files
    )
    await installer.install()
    let folderURL = try #require(installer.installedModelFolderURL)
    #expect(FileManager.default.fileExists(atPath: folderURL.path))

    await installer.deleteInstalledModel()

    #expect(installer.state == .absent)
    #expect(storage.state == .absent)
    #expect(!FileManager.default.fileExists(atPath: folderURL.path))
  }

  @Test func diskFullPreflightFailsBeforeNetworkDownload() async {
    let appSupport = Self.makeApplicationSupportDirectory()
    defer { Self.remove(appSupport) }
    let storage = InMemoryWhisperKitModelStateStorage()
    let downloader = FakeWhisperKitModelFileDownloader(contents: Self.fixtureManifest().contents)
    let installer = WhisperKitModelInstaller(
      stateStorage: storage,
      fileDownloader: downloader,
      applicationSupportDirectory: appSupport,
      availableCapacityProvider: { _ in WhisperKitModelInstaller.expectedModelSizeBytes * 2 - 1 }
    )

    await installer.install()

    guard case .failed(let failure) = installer.state else {
      Issue.record("expected failed state, got \(installer.state)")
      return
    }
    #expect(failure.kind == .disk)
    #expect(failure.isRetryable)
    #expect(downloader.downloadedRelativePaths.isEmpty)
  }

  @Test func diskFullErrorsMapToDiskFailureTaxonomy() {
    let failures = [
      whisperKitModelDownloadFailure(
        for: WhisperKitModelInstallError.insufficientDiskSpace(
          requiredBytes: 200,
          availableBytes: 99
        )),
      whisperKitModelDownloadFailure(for: CocoaError(.fileWriteOutOfSpace)),
      whisperKitModelDownloadFailure(for: POSIXError(.ENOSPC)),
    ]

    for failure in failures {
      #expect(failure.kind == .disk)
      #expect(failure.isRetryable)
      #expect(failure.userSafeReason.contains("storage"))
    }
  }

  // why: C2 — a specifically-offline device maps to `.offline` (distinct copy), NOT the generic
  // `.network` failure, so the pilot is told to reconnect rather than "check the connection".
  @Test func offlineErrorsMapToOfflineFailureTaxonomyDistinctFromNetwork() {
    for code in [
      URLError.Code.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
    ] {
      let failure = whisperKitModelDownloadFailure(for: URLError(code))
      #expect(failure.kind == .offline)
      #expect(failure.isRetryable)
    }
    let generic = whisperKitModelDownloadFailure(for: URLError(.badServerResponse))
    #expect(generic.kind == .network)
    let offline = whisperKitModelDownloadFailure(for: URLError(.notConnectedToInternet))
    #expect(offline.userSafeReason != generic.userSafeReason)
  }

  // why: C1 — an interrupted install must not restart completed files from zero. A network drop
  // partway leaves the finished files staged; the retry re-downloads only what it still needs.
  @Test func interruptedInstallResumesCompletedFilesOnRetry() async throws {
    let appSupport = Self.makeApplicationSupportDirectory()
    defer { Self.remove(appSupport) }
    let (files, contents) = Self.fixtureManifest()
    let storage = InMemoryWhisperKitModelStateStorage()
    let failPath = files[2].relativePath
    let downloader = ScriptedWhisperKitDownloader(
      contents: contents, failOnceAt: failPath, error: URLError(.networkConnectionLost))

    await Self.makeInstaller(storage, downloader, appSupport, files).install()
    guard case .failed(let firstFailure) = storage.state else {
      Issue.record("expected failed state, got \(storage.state)")
      return
    }
    #expect(firstFailure.kind == .offline)
    #expect(downloader.downloadedRelativePaths.contains(files[0].relativePath))
    #expect(downloader.downloadedRelativePaths.contains(files[1].relativePath))
    #expect(!downloader.downloadedRelativePaths.contains(failPath))

    downloader.reset()
    await Self.makeInstaller(storage, downloader, appSupport, files).install()
    guard case .installed = storage.state else {
      Issue.record("expected installed state, got \(storage.state)")
      return
    }
    #expect(!downloader.downloadedRelativePaths.contains(files[0].relativePath))
    #expect(!downloader.downloadedRelativePaths.contains(files[1].relativePath))
    #expect(downloader.downloadedRelativePaths.contains(failPath))
  }

  // why: C1 — a staged file that fails the pinned SHA-256 is deleted (never fail-open, never a stale
  // skip): the retry re-downloads exactly that file while still skipping the good ones.
  @Test func checksumFailureCleansStagedFileSoRetryReDownloadsIt() async throws {
    let appSupport = Self.makeApplicationSupportDirectory()
    defer { Self.remove(appSupport) }
    let (files, contents) = Self.fixtureManifest()
    let storage = InMemoryWhisperKitModelStateStorage()
    let corruptPath = files[1].relativePath
    let downloader = ScriptedWhisperKitDownloader(
      contents: contents, corruptOnceAt: corruptPath)

    await Self.makeInstaller(storage, downloader, appSupport, files).install()
    guard case .failed(let failure) = storage.state else {
      Issue.record("expected failed state, got \(storage.state)")
      return
    }
    #expect(failure.kind == .checksum)

    downloader.reset()
    await Self.makeInstaller(storage, downloader, appSupport, files).install()
    guard case .installed = storage.state else {
      Issue.record("expected installed state, got \(storage.state)")
      return
    }
    #expect(downloader.downloadedRelativePaths.contains(corruptPath))
    #expect(!downloader.downloadedRelativePaths.contains(files[0].relativePath))
  }

  private static func makeInstaller(
    _ storage: InMemoryWhisperKitModelStateStorage,
    _ downloader: any WhisperKitModelFileDownloading,
    _ appSupport: URL,
    _ files: [WhisperKitModelInstaller.ExpectedModelFile]
  ) -> WhisperKitModelInstaller {
    WhisperKitModelInstaller(
      stateStorage: storage,
      fileDownloader: downloader,
      applicationSupportDirectory: appSupport,
      availableCapacityProvider: { _ in 1_000_000_000 },
      now: { Date(timeIntervalSince1970: 1_718_000_000) },
      expectedFiles: files
    )
  }

  // why: B4 — the installer now verifies each downloaded file against its manifest SHA-256, so the
  // fake install path needs a manifest whose hashes match the fixture bytes (real model bytes can't
  // be reproduced from preimages). Covers all 17 pinned relative paths; config.json keeps its short
  // "config" fixture so the per-file sha assertion stays meaningful.
  private static func fixtureManifest() -> (
    files: [WhisperKitModelInstaller.ExpectedModelFile], contents: [String: Data]
  ) {
    var files: [WhisperKitModelInstaller.ExpectedModelFile] = []
    var contents: [String: Data] = [:]
    for expected in WhisperKitModelInstaller.expectedModelFiles {
      let data =
        expected.relativePath == "config.json"
        ? Data("config".utf8) : Data(expected.relativePath.utf8)
      contents[expected.relativePath] = data
      files.append(
        WhisperKitModelInstaller.ExpectedModelFile(
          relativePath: expected.relativePath,
          sizeBytes: Int64(data.count),
          expectedSHA256: Self.sha256(data)
        ))
    }
    return (files, contents)
  }

  private static func installedModel(localModelPath: String) -> WhisperKitInstalledModel {
    WhisperKitInstalledModel(
      name: WhisperKitModelInstaller.modelName,
      repository: WhisperKitModelInstaller.repository,
      revision: WhisperKitModelInstaller.pinnedRevision,
      files: [
        WhisperKitInstalledModelFile(
          relativePath: "config.json",
          sha256: Self.sha256(Data("config".utf8)),
          sizeBytes: 6
        )
      ],
      sizeBytes: 6,
      installedAt: Date(timeIntervalSince1970: 1_718_000_000),
      localModelPath: localModelPath
    )
  }

  private static func makeApplicationSupportDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dspeech-whisperkit-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func remove(_ url: URL) {
    if FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private final class InMemoryWhisperKitModelStateStorage: WhisperKitModelStateStorage,
  @unchecked Sendable
{
  var state: WhisperKitModelInstallState = .absent
  var savedStates: [WhisperKitModelInstallState] = []

  func loadState() -> WhisperKitModelInstallState { state }

  func saveState(_ state: WhisperKitModelInstallState) {
    self.state = state
    savedStates.append(state)
  }
}

private final class FakeWhisperKitModelFileDownloader: WhisperKitModelFileDownloading,
  @unchecked Sendable
{
  private let contents: [String: Data]
  private(set) var downloadedRelativePaths: [String] = []

  init(contents: [String: Data]) {
    self.contents = contents
  }

  func download(from sourceURL: URL, to destinationURL: URL) async throws {
    let relativePath = destinationURL.pathComponents.suffix(3).joined(separator: "/")
    let modelRelativePath = Self.modelRelativePath(from: destinationURL)
    let data = try #require(contents[modelRelativePath], "missing fixture for \(relativePath)")
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: destinationURL, options: .atomic)
    downloadedRelativePaths.append(modelRelativePath)
    #expect(sourceURL.absoluteString.contains(WhisperKitModelInstaller.pinnedRevision))
  }

  private static func modelRelativePath(from url: URL) -> String {
    let components = url.pathComponents
    guard
      let index = components.lastIndex(of: WhisperKitModelInstaller.modelFolderName),
      index + 1 < components.endIndex
    else {
      return url.lastPathComponent
    }
    return components[(index + 1)...].joined(separator: "/")
  }
}

// why: C1 — a downloader that fails (network) or corrupts a chosen file exactly ONCE, then behaves
// on the retry, so a test can prove staged-file resume and corrupt-file cleanup across two attempts.
private final class ScriptedWhisperKitDownloader: WhisperKitModelFileDownloading,
  @unchecked Sendable
{
  // why: the installer downloads files sequentially (awaits each), so this fake's mutable state is
  // only ever touched from one task at a time — no lock needed (and NSLock is unusable in async).
  private let contents: [String: Data]
  private let failOncePath: String?
  private let failError: Error?
  private let corruptOncePath: String?
  private var didFail = false
  private var didCorrupt = false
  private(set) var downloadedRelativePaths: [String] = []

  init(
    contents: [String: Data],
    failOnceAt failOncePath: String? = nil,
    error failError: Error? = nil,
    corruptOnceAt corruptOncePath: String? = nil
  ) {
    self.contents = contents
    self.failOncePath = failOncePath
    self.failError = failError
    self.corruptOncePath = corruptOncePath
  }

  func reset() {
    downloadedRelativePaths.removeAll()
  }

  func download(from sourceURL: URL, to destinationURL: URL) async throws {
    let relativePath = Self.modelRelativePath(from: destinationURL)
    let shouldFail = relativePath == failOncePath && !didFail
    if shouldFail { didFail = true }
    let shouldCorrupt = relativePath == corruptOncePath && !didCorrupt
    if shouldCorrupt { didCorrupt = true }
    if shouldFail {
      throw failError ?? URLError(.networkConnectionLost)
    }
    let data =
      shouldCorrupt
      ? Data("corrupted-\(relativePath)".utf8)
      : try #require(contents[relativePath], "missing fixture for \(relativePath)")
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: destinationURL, options: .atomic)
    downloadedRelativePaths.append(relativePath)
  }

  private static func modelRelativePath(from url: URL) -> String {
    let components = url.pathComponents
    guard
      let index = components.lastIndex(of: WhisperKitModelInstaller.modelFolderName),
      index + 1 < components.endIndex
    else {
      return url.lastPathComponent
    }
    return components[(index + 1)...].joined(separator: "/")
  }
}

// why: C1 — the resumable single-file staged download primitive, tested independently of the network
// via an injected `fetch` seam. Covers: complete-file skip, fresh download (200), range-resume (206
// appends onto the partial), and a server that ignores Range (200 replaces the stale partial).
struct ResumableStagedDownloadTests {
  private func makeDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dspeech-resume-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func completeFileIsSkippedWithoutFetching() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("model.bin")
    let full = Data("already-complete".utf8)
    try full.write(to: destination)
    var fetchCalls = 0

    try await resumableStagedDownload(to: destination) { _ in
      fetchCalls += 1
      let body = dir.appendingPathComponent("body-\(UUID().uuidString)")
      try Data("should-not-be-used".utf8).write(to: body)
      return ResumableDownloadResponse(statusCode: 200, bodyFileURL: body)
    }

    #expect(fetchCalls == 0)
    #expect(try Data(contentsOf: destination) == full)
  }

  @Test func freshDownloadStagesFullBodyFromOffsetZero() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("model.bin")
    let full = Data("hello world".utf8)
    var capturedOffset: Int64 = -1

    try await resumableStagedDownload(to: destination) { offset in
      capturedOffset = offset
      let body = dir.appendingPathComponent("body-\(UUID().uuidString)")
      try full.write(to: body)
      return ResumableDownloadResponse(statusCode: 200, bodyFileURL: body)
    }

    #expect(capturedOffset == 0)
    #expect(try Data(contentsOf: destination) == full)
    #expect(
      !FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
  }

  @Test func partialFileResumesViaRangeAndAppends() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("model.bin")
    let head = Data("hello ".utf8)
    let tail = Data("world".utf8)
    try head.write(to: destination.appendingPathExtension("partial"))
    var capturedOffset: Int64 = -1

    try await resumableStagedDownload(to: destination) { offset in
      capturedOffset = offset
      let body = dir.appendingPathComponent("body-\(UUID().uuidString)")
      try tail.write(to: body)
      return ResumableDownloadResponse(statusCode: 206, bodyFileURL: body)
    }

    #expect(capturedOffset == Int64(head.count))
    #expect(try Data(contentsOf: destination) == head + tail)
  }

  @Test func serverIgnoringRangeDiscardsStalePartialAndUsesFullBody() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("model.bin")
    let full = Data("complete-fresh-body".utf8)
    try Data("stale".utf8).write(to: destination.appendingPathExtension("partial"))
    var capturedOffset: Int64 = -1

    try await resumableStagedDownload(to: destination) { offset in
      capturedOffset = offset
      let body = dir.appendingPathComponent("body-\(UUID().uuidString)")
      try full.write(to: body)
      return ResumableDownloadResponse(statusCode: 200, bodyFileURL: body)
    }

    #expect(capturedOffset == 5)
    #expect(try Data(contentsOf: destination) == full)
  }
}
