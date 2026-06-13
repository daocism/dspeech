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
    #expect(
      try WhisperKitModelInstaller.pinnedDownloadURL(relativePath: "config.json").absoluteString
        == "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/97a5bf9bbc74c7d9c12c755d04dea59e672e3808/openai_whisper-large-v3-v20240930_626MB/config.json"
    )
  }

  @Test func installDownloadsPinnedFilesAndRecordsChecksumManifest() async throws {
    let appSupport = Self.makeApplicationSupportDirectory()
    defer { Self.remove(appSupport) }
    let storage = InMemoryWhisperKitModelStateStorage()
    let downloader = FakeWhisperKitModelFileDownloader(
      contents: Self.fixtureContents()
    )
    let installer = WhisperKitModelInstaller(
      stateStorage: storage,
      fileDownloader: downloader,
      applicationSupportDirectory: appSupport,
      availableCapacityProvider: { _ in WhisperKitModelInstaller.expectedModelSizeBytes * 2 },
      now: { Date(timeIntervalSince1970: 1_718_000_000) }
    )

    await installer.install()

    guard case .installed(let model) = installer.state else {
      Issue.record("expected installed state, got \(installer.state)")
      return
    }
    let folderURL = try #require(installer.installedModelFolderURL)
    #expect(folderURL.path.hasSuffix("WhisperKit/Models/openai_whisper-large-v3-v20240930_626MB"))
    #expect(FileManager.default.fileExists(atPath: folderURL.path))
    #expect(model.files.count == WhisperKitModelInstaller.expectedModelFiles.count)
    #expect(
      model.sizeBytes == Self.fixtureContents().values.reduce(Int64(0)) { $0 + Int64($1.count) })
    #expect(model.revision == WhisperKitModelInstaller.pinnedRevision)
    #expect(
      model.files.first { $0.relativePath == "config.json" }?.sha256
        == Self.sha256(Data("config".utf8)))
    #expect(
      downloader.downloadedRelativePaths
        == WhisperKitModelInstaller.expectedModelFiles.map(\.relativePath))
    #expect(storage.savedStates.contains { if case .downloading = $0 { true } else { false } })
    #expect(storage.state == .installed(model))
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
    let storage = InMemoryWhisperKitModelStateStorage()
    let downloader = FakeWhisperKitModelFileDownloader(contents: Self.fixtureContents())
    let installer = WhisperKitModelInstaller(
      stateStorage: storage,
      fileDownloader: downloader,
      applicationSupportDirectory: appSupport,
      availableCapacityProvider: { _ in WhisperKitModelInstaller.expectedModelSizeBytes * 2 }
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
    let downloader = FakeWhisperKitModelFileDownloader(contents: Self.fixtureContents())
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

  private static func fixtureContents() -> [String: Data] {
    Dictionary(
      uniqueKeysWithValues: WhisperKitModelInstaller.expectedModelFiles.map {
        ($0.relativePath, Data($0.relativePath.utf8))
      }
    )
    .merging(["config.json": Data("config".utf8)]) { _, replacement in replacement }
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
