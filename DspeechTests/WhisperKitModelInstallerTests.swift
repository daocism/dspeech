import CryptoKit
import Foundation
import PropertyBased
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

// MARK: - C3 resume-cache accessor tests (hasPartialStaging / byte count / kept fraction)

// why: C3 — the pause/resume UI reads three read-only accessors over the C1 staging cache. They had
// ZERO direct coverage; these pin their semantics: absent staging → false/0/0; staged bytes present
// → true/bytes/fraction; the kept fraction is bytes÷manifest-total, clamped to 1 even when more bytes
// are staged than the manifest expects (a complete-but-unverified staging folder counts fully).
@MainActor
struct WhisperKitModelStagingAccessorTests {
  // Two fixture files summing to 100 bytes so the kept fraction is exact and easy to reason about.
  private static func fixtureFiles() -> [WhisperKitModelInstaller.ExpectedModelFile] {
    [
      WhisperKitModelInstaller.ExpectedModelFile(
        relativePath: "a.bin", sizeBytes: 60, expectedSHA256: String(repeating: "a", count: 64)),
      WhisperKitModelInstaller.ExpectedModelFile(
        relativePath: "b.bin", sizeBytes: 40, expectedSHA256: String(repeating: "b", count: 64)),
    ]
  }

  private static func makeApplicationSupportDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dspeech-whisperkit-staging-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func remove(_ url: URL) {
    if FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private static func makeInstaller(
    appSupport: URL,
    files: [WhisperKitModelInstaller.ExpectedModelFile] = fixtureFiles()
  ) -> WhisperKitModelInstaller {
    WhisperKitModelInstaller(
      stateStorage: InMemoryWhisperKitModelStateStorage(),
      fileDownloader: FakeWhisperKitModelFileDownloader(contents: [:]),
      applicationSupportDirectory: appSupport,
      availableCapacityProvider: { _ in 1_000_000_000 },
      expectedFiles: files
    )
  }

  // Writes `bytes` of staged content into the model's stable staging root (the C1 resume cache).
  private static func stage(bytes: Int, named name: String, appSupport: URL) throws {
    let stagingRoot =
      appSupport
      .appendingPathComponent("WhisperKit/Models", isDirectory: true)
      .appendingPathComponent(
        ".\(WhisperKitModelInstaller.modelFolderName).staging", isDirectory: true
      )
      .appendingPathComponent(WhisperKitModelInstaller.modelFolderName, isDirectory: true)
    try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    try Data(repeating: 0, count: bytes).write(to: stagingRoot.appendingPathComponent(name))
  }

  @Test func absentStagingReportsNothingKept() {
    let appSupport = Self.makeApplicationSupportDirectory()
    defer { Self.remove(appSupport) }
    let installer = Self.makeInstaller(appSupport: appSupport)

    #expect(installer.partialStagingByteCount == 0)
    #expect(installer.hasPartialStaging == false)
    #expect(installer.stagedFractionKept == 0)
  }

  @Test func partialStagingReportsByteCountAndFraction() throws {
    let appSupport = Self.makeApplicationSupportDirectory()
    defer { Self.remove(appSupport) }
    try Self.stage(bytes: 25, named: "a.bin.partial", appSupport: appSupport)
    let installer = Self.makeInstaller(appSupport: appSupport)

    #expect(installer.partialStagingByteCount == 25)
    #expect(installer.hasPartialStaging)
    // 25 of 100 expected bytes kept.
    #expect(abs(installer.stagedFractionKept - 0.25) < 1e-9)
  }

  @Test func stagedBytesAcrossMultipleFilesSum() throws {
    let appSupport = Self.makeApplicationSupportDirectory()
    defer { Self.remove(appSupport) }
    try Self.stage(bytes: 30, named: "a.bin", appSupport: appSupport)
    try Self.stage(bytes: 30, named: "b.bin", appSupport: appSupport)
    let installer = Self.makeInstaller(appSupport: appSupport)

    #expect(installer.partialStagingByteCount == 60)
    #expect(installer.hasPartialStaging)
    #expect(abs(installer.stagedFractionKept - 0.6) < 1e-9)
  }

  @Test func keptFractionClampsToOneWhenStagedExceedsManifestTotal() throws {
    let appSupport = Self.makeApplicationSupportDirectory()
    defer { Self.remove(appSupport) }
    // a complete-but-unverified staging folder can hold more bytes than the manifest sum (e.g. a
    // `.partial` alongside a completed file); the kept fraction must never exceed 1.0.
    try Self.stage(bytes: 150, named: "a.bin", appSupport: appSupport)
    let installer = Self.makeInstaller(appSupport: appSupport)

    #expect(installer.partialStagingByteCount == 150)
    #expect(installer.stagedFractionKept == 1)
  }

  @Test func keptFractionIsZeroWhenManifestTotalIsZero() throws {
    let appSupport = Self.makeApplicationSupportDirectory()
    defer { Self.remove(appSupport) }
    try Self.stage(bytes: 50, named: "a.bin", appSupport: appSupport)
    // an empty manifest → zero expected bytes → the guard returns 0 rather than dividing by zero,
    // even though staged bytes are present (hasPartialStaging still reflects the real bytes).
    let installer = Self.makeInstaller(appSupport: appSupport, files: [])

    #expect(installer.partialStagingByteCount == 50)
    #expect(installer.hasPartialStaging)
    #expect(installer.stagedFractionKept == 0)
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

// MARK: - F13 — PropertyBased state-machine properties (WhisperKit installer)

// why: F13 — property-based coverage of the WhisperKit install state machine over generated
// per-file download-outcome sequences (success / checksum-mismatch / generic-network / offline /
// cancel at random positions). These are NEW PropertyBased (x-sheep) suites; the existing
// example-based tests above stay as-is (plan A8). Each property carries a REACH gate (a counter of
// how many generated sequences actually exercised each branch) so a "green" run can't be vacuous —
// a branch that was never generated fails the suite (vacuous-guard rule).

// A per-file download outcome the fake downloader enacts.
private enum WhisperKitDownloadFault: Sendable, Equatable {
  case success
  case checksumMismatch
  case networkError
  case offline
  case cancel
}

// why: file-scope (not a @MainActor static) so the @Sendable generator `.map` closure can capture it.
private let whisperKitFailureKinds: [WhisperKitDownloadFault] = [
  .checksumMismatch, .networkError, .offline, .cancel,
]

// why: MainActor-isolated branch-reach tallies. A property that never generated a given branch is a
// vacuous property; the post-check `#expect(... > 0)` turns "we exercised it" into a hard gate.
@MainActor
private final class WhisperKitInstallerReach {
  var installed = 0
  var checksum = 0
  var network = 0
  var offline = 0
  var cancel = 0
  var converged = 0
  var resumeSkipped = 0
}

// A downloader that enacts a per-relative-path fault. Success writes the fixture bytes (which hash to
// the manifest SHA-256, so the engine's integrity gate accepts them); checksumMismatch writes bytes
// that can't match; the network/offline/cancel faults throw the mapped error BEFORE writing.
private final class ProgrammableWhisperKitDownloader: WhisperKitModelFileDownloading,
  @unchecked Sendable
{
  // why: the installer awaits each file sequentially, so this mutable state is only ever touched from
  // one task at a time (same rationale as ScriptedWhisperKitDownloader above).
  private let contents: [String: Data]
  private let faultByPath: [String: WhisperKitDownloadFault]
  private(set) var attempted: [String] = []

  init(contents: [String: Data], faultByPath: [String: WhisperKitDownloadFault]) {
    self.contents = contents
    self.faultByPath = faultByPath
  }

  func download(from sourceURL: URL, to destinationURL: URL) async throws {
    let relativePath = Self.modelRelativePath(from: destinationURL)
    attempted.append(relativePath)
    switch faultByPath[relativePath] ?? .success {
    case .networkError:
      throw URLError(.badServerResponse)
    case .offline:
      throw URLError(.notConnectedToInternet)
    case .cancel:
      throw CancellationError()
    case .checksumMismatch, .success:
      let data =
        (faultByPath[relativePath] == .checksumMismatch)
        ? Data("corrupted-\(relativePath)".utf8)
        : (contents[relativePath] ?? Data())
      try FileManager.default.createDirectory(
        at: destinationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: destinationURL, options: .atomic)
    }
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

@MainActor
struct WhisperKitInstallerPropertyTests {
  // A small deterministic fixture manifest (6 files, distinct bytes hashing to the manifest SHA-256),
  // large enough that a fault at index > 0 leaves earlier files staged for the resume-skip property.
  private static let fileCount = 6

  private static func fixture() -> (
    files: [WhisperKitModelInstaller.ExpectedModelFile], contents: [String: Data]
  ) {
    var files: [WhisperKitModelInstaller.ExpectedModelFile] = []
    var contents: [String: Data] = [:]
    for index in 0..<fileCount {
      let relativePath = "part\(index).mlmodelc/weights/weight.bin"
      let data = Data("whisperkit-pbt-fixture:\(index)".utf8)
      contents[relativePath] = data
      files.append(
        WhisperKitModelInstaller.ExpectedModelFile(
          relativePath: relativePath,
          sizeBytes: Int64(data.count),
          expectedSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        ))
    }
    return (files, contents)
  }

  private static func makeApplicationSupportDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dspeech-whisperkit-pbt-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func makeInstaller(
    _ storage: any WhisperKitModelStateStorage,
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

  private static func finalFolder(_ appSupport: URL) -> URL {
    appSupport.appendingPathComponent(
      "WhisperKit/Models/\(WhisperKitModelInstaller.modelFolderName)", isDirectory: true)
  }

  // Per-file fault generator, biased toward success (~60%) so all-success sequences occur often
  // enough to reach the .installed branch, while every failure kind is generated frequently.
  private static func perFileFaultGenerator()
    -> Generator<WhisperKitDownloadFault, some SendableSequenceType>
  {
    Gen.int(in: 0...9).map { code in
      switch code {
      case 0, 1, 2, 3, 4, 5: return .success
      case 6: return .checksumMismatch
      case 7: return .networkError
      case 8: return .offline
      default: return .cancel
      }
    }
  }

  private static func failureKindGenerator()
    -> Generator<WhisperKitDownloadFault, some SendableSequenceType>
  {
    Gen.int(in: 0..<whisperKitFailureKinds.count).map { whisperKitFailureKinds[$0] }
  }

  // Properties (a) terminal state is ALWAYS installed/failed (never a stuck intermediate),
  // (b) a checksum mismatch NEVER ends installed, (c) after ANY failure no complete unverified model
  // dir exists — all follow from: the terminal state deterministically matches the DECISIVE fault
  // (the first non-success file), and any failure leaves the atomically-moved final folder absent.
  @Test func terminalStateMatchesDecisiveFaultAndFailureLeavesNoModelFolder() async {
    let reach = WhisperKitInstallerReach()
    await propertyCheck(
      count: 240, input: Self.perFileFaultGenerator().array(of: Self.fileCount)
    ) { faults in
      let appSupport = Self.makeApplicationSupportDirectory()
      defer { try? FileManager.default.removeItem(at: appSupport) }
      let (files, contents) = Self.fixture()
      let faultByPath = Dictionary(
        uniqueKeysWithValues: zip(files.map(\.relativePath), faults))
      let storage = PBTWhisperKitStateStorage()
      let downloader = ProgrammableWhisperKitDownloader(
        contents: contents, faultByPath: faultByPath)
      let installer = Self.makeInstaller(storage, downloader, appSupport, files)

      await installer.install()

      // (a) terminal: never a stuck intermediate (.downloading) and never still .absent.
      switch installer.state {
      case .installed, .failed:
        break
      case .absent, .downloading:
        Issue.record("non-terminal state after install(): \(installer.state)")
      }

      let decisive = zip(files, faults).first { $0.1 != .success }?.1
      switch decisive {
      case nil:
        guard case .installed = installer.state else {
          Issue.record("all-success sequence did not install: \(installer.state)")
          return
        }
        reach.installed += 1
        #expect(FileManager.default.fileExists(atPath: Self.finalFolder(appSupport).path))
      case .checksumMismatch:
        // (b) checksum mismatch NEVER ends installed.
        Self.expectFailed(installer.state, kind: .checksum)
        reach.checksum += 1
      case .networkError:
        Self.expectFailed(installer.state, kind: .network)
        reach.network += 1
      case .offline:
        Self.expectFailed(installer.state, kind: .offline)
        reach.offline += 1
      case .cancel:
        Self.expectFailed(installer.state, kind: .cancelled)
        reach.cancel += 1
      case .success:
        Issue.record("decisive fault should never be .success")
      }

      // (c) after ANY failure: the atomic move never happened, so no complete model dir exists.
      if case .failed = installer.state {
        #expect(installer.installedModelFolderURL == nil)
        #expect(!FileManager.default.fileExists(atPath: Self.finalFolder(appSupport).path))
      }
    }

    // REACH gates — every branch must have been generated, or the property is vacuous.
    #expect(reach.installed > 0)
    #expect(reach.checksum > 0)
    #expect(reach.network > 0)
    #expect(reach.offline > 0)
    #expect(reach.cancel > 0)
  }

  // Property (d) retry after a partial ALWAYS converges to installed when the retry's downloads all
  // succeed — and the already-staged (verified) files from the first attempt are NOT re-downloaded.
  // The fault is forced at a generated index so `decisiveIndex > 0` reliably exercises resume-skip.
  @Test func retryAfterPartialConvergesAndSkipsStagedFiles() async {
    let reach = WhisperKitInstallerReach()
    let input = zip(
      Gen.int(in: 0..<Self.fileCount),
      Self.failureKindGenerator()
    )
    await propertyCheck(count: 180, input: input) { failIndex, failKind in
      let appSupport = Self.makeApplicationSupportDirectory()
      defer { try? FileManager.default.removeItem(at: appSupport) }
      let (files, contents) = Self.fixture()
      var faults = [WhisperKitDownloadFault](repeating: .success, count: files.count)
      faults[failIndex] = failKind
      let faultByPath = Dictionary(
        uniqueKeysWithValues: zip(files.map(\.relativePath), faults))
      let storage = PBTWhisperKitStateStorage()

      // First attempt fails at the forced index (all earlier files succeed → staged).
      let firstDownloader = ProgrammableWhisperKitDownloader(
        contents: contents, faultByPath: faultByPath)
      await Self.makeInstaller(storage, firstDownloader, appSupport, files).install()
      guard case .failed = storage.state else {
        Issue.record("forced-fault install did not fail: \(storage.state)")
        return
      }

      // Retry with an all-success downloader, SAME storage + Application Support (staging persists).
      let retryDownloader = ProgrammableWhisperKitDownloader(
        contents: contents, faultByPath: [:])
      await Self.makeInstaller(storage, retryDownloader, appSupport, files).install()
      guard case .installed = storage.state else {
        Issue.record("retry did not converge to installed: \(storage.state)")
        return
      }
      reach.converged += 1

      // Files verified before the failing index are the resume cache — the retry must skip them.
      if failIndex > 0 {
        let staged = files[0..<failIndex].map(\.relativePath)
        #expect(staged.allSatisfy { !retryDownloader.attempted.contains($0) })
        // The failing file itself IS re-downloaded on retry.
        #expect(retryDownloader.attempted.contains(files[failIndex].relativePath))
        reach.resumeSkipped += 1
      }
    }

    #expect(reach.converged > 0)
    #expect(reach.resumeSkipped > 0)
  }

  private static func expectFailed(
    _ state: WhisperKitModelInstallState,
    kind: WhisperKitModelInstallFailure.Kind,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    guard case .failed(let failure) = state else {
      Issue.record("expected .failed(\(kind)), got \(state)", sourceLocation: sourceLocation)
      return
    }
    #expect(failure.kind == kind, sourceLocation: sourceLocation)
  }
}

private final class PBTWhisperKitStateStorage: WhisperKitModelStateStorage, @unchecked Sendable {
  var state: WhisperKitModelInstallState = .absent

  func loadState() -> WhisperKitModelInstallState { state }
  func saveState(_ state: WhisperKitModelInstallState) { self.state = state }
}
