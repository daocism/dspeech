import CryptoKit
import Foundation
import Testing

@testable import Dspeech

@MainActor
struct ParakeetModelInstallerTests {
  @Test func productionModelPinsHuggingFaceRevisionAndFileList() throws {
    #expect(ParakeetModelInstaller.modelName == "parakeet-realtime-eou-120m")
    #expect(ParakeetModelInstaller.modelFolderName == "160ms")
    #expect(
      ParakeetModelInstaller.repository == "FluidInference/parakeet-realtime-eou-120m-coreml")
    #expect(
      ParakeetModelInstaller.sourceRevision == "40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355")
    #expect(ParakeetModelInstaller.expectedModelFiles.count == 16)
    #expect(ParakeetModelInstaller.expectedModelSizeBytes == 224_047_838)
    // why: every shipped file must carry a 64-hex-char SHA-256 — no placeholder/empty hashes.
    #expect(
      ParakeetModelInstaller.expectedModelFiles.allSatisfy {
        $0.expectedSHA256.count == 64
          && $0.expectedSHA256.allSatisfy { $0.isHexDigit }
      })
    #expect(
      try ParakeetModelInstaller.pinnedDownloadURL(relativePath: "vocab.json").absoluteString
        == "https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml/resolve/40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355/160ms/vocab.json"
    )
  }

  @Test func installDownloadsPinnedFilesAndVerifiesChecksumManifest() async throws {
    let appSupport = Self.makeApplicationSupportDirectory()
    defer { Self.remove(appSupport) }
    let (files, contents) = Self.fixtureManifest()
    let storage = InMemoryParakeetModelStateStorage()
    let downloader = FakeParakeetModelFileDownloader { contents[$0]! }
    let installer = ParakeetModelInstaller(
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
    #expect(
      folderURL.path.hasSuffix("FluidAudio/Models/parakeet-realtime-eou-120m-coreml/160ms"))
    #expect(FileManager.default.fileExists(atPath: folderURL.path))
    #expect(model.files.count == files.count)
    #expect(model.revision == ParakeetModelInstaller.sourceRevision)
    for file in files {
      let recorded = try #require(model.files.first { $0.relativePath == file.relativePath })
      #expect(recorded.sha256.lowercased() == file.expectedSHA256.lowercased())
    }
    #expect(storage.savedStates.contains { if case .downloading = $0 { true } else { false } })
    #expect(storage.state == .installed(model))
  }

  // why: the upgrade vs WhisperKit — a downloaded file that does NOT match the pinned SHA-256
  // must fail the install (never fail-open, never install a tampered/corrupt CoreML bundle).
  @Test func checksumMismatchFailsInstallAndLeavesNoModelFolder() async {
    let appSupport = Self.makeApplicationSupportDirectory()
    defer { Self.remove(appSupport) }
    let storage = InMemoryParakeetModelStateStorage()
    // the REAL pinned manifest, but the downloader yields bytes that can't match any real hash
    let downloader = FakeParakeetModelFileDownloader { _ in Data("corrupted-bytes".utf8) }
    let installer = ParakeetModelInstaller(
      stateStorage: storage,
      fileDownloader: downloader,
      applicationSupportDirectory: appSupport,
      availableCapacityProvider: { _ in ParakeetModelInstaller.expectedModelSizeBytes * 2 }
    )

    await installer.install()

    guard case .failed(let failure) = installer.state else {
      Issue.record("expected failed state, got \(installer.state)")
      return
    }
    #expect(failure.kind == .checksum)
    #expect(installer.installedModelFolderURL == nil)
    let finalFolder = appSupport.appendingPathComponent(
      "FluidAudio/Models/parakeet-realtime-eou-120m-coreml/160ms")
    #expect(!FileManager.default.fileExists(atPath: finalFolder.path))
  }

  @Test func deleteInstalledModelRemovesFolderAndReturnsToAbsent() async throws {
    let appSupport = Self.makeApplicationSupportDirectory()
    defer { Self.remove(appSupport) }
    let (files, contents) = Self.fixtureManifest()
    let storage = InMemoryParakeetModelStateStorage()
    let downloader = FakeParakeetModelFileDownloader { contents[$0]! }
    let installer = ParakeetModelInstaller(
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
    let (files, contents) = Self.fixtureManifest()
    let storage = InMemoryParakeetModelStateStorage()
    let downloader = FakeParakeetModelFileDownloader { contents[$0]! }
    let totalSize = files.reduce(Int64(0)) { $0 + $1.sizeBytes }
    let installer = ParakeetModelInstaller(
      stateStorage: storage,
      fileDownloader: downloader,
      applicationSupportDirectory: appSupport,
      availableCapacityProvider: { _ in totalSize * 2 - 1 },
      expectedFiles: files
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

  @Test func coldStartRecoveryResetsInterruptedDownloadToAbsent() {
    let progress = ParakeetModelDownloadProgress(
      fractionComplete: 0.4, bytesReceived: 40, totalBytes: 100)
    #expect(ParakeetModelInstallState.downloading(progress).recoveredAfterColdStart() == .absent)
    let model = Self.installedModel()
    #expect(
      ParakeetModelInstallState.installed(model).recoveredAfterColdStart()
        == .installed(model))
  }

  @Test func checksumMismatchMapsToChecksumFailureTaxonomy() {
    let failure = parakeetModelDownloadFailure(
      for: ParakeetModelInstallError.checksumMismatch(
        relativePath: "vocab.json", expected: "aaa", actual: "bbb"))
    #expect(failure.kind == .checksum)
    #expect(failure.isRetryable)
  }

  @Test func diskFullErrorsMapToDiskFailureTaxonomy() {
    let failures = [
      parakeetModelDownloadFailure(
        for: ParakeetModelInstallError.insufficientDiskSpace(
          requiredBytes: 200, availableBytes: 99)),
      parakeetModelDownloadFailure(for: CocoaError(.fileWriteOutOfSpace)),
      parakeetModelDownloadFailure(for: POSIXError(.ENOSPC)),
    ]
    for failure in failures {
      #expect(failure.kind == .disk)
      #expect(failure.isRetryable)
      #expect(failure.userSafeReason.contains("storage"))
    }
  }

  private static func fixtureManifest() -> (
    files: [ParakeetModelInstaller.ExpectedModelFile], contents: [String: Data]
  ) {
    let relativePaths = [
      "streaming_encoder.mlmodelc/analytics/coremldata.bin",
      "streaming_encoder.mlmodelc/weights/weight.bin",
      "decoder.mlmodelc/model.mil",
      "joint_decision.mlmodelc/metadata.json",
      "vocab.json",
    ]
    var files: [ParakeetModelInstaller.ExpectedModelFile] = []
    var contents: [String: Data] = [:]
    for path in relativePaths {
      let data = Data("parakeet-fixture:\(path)".utf8)
      contents[path] = data
      files.append(
        ParakeetModelInstaller.ExpectedModelFile(
          relativePath: path,
          sizeBytes: Int64(data.count),
          expectedSHA256: Self.sha256(data)
        ))
    }
    return (files, contents)
  }

  private static func installedModel() -> ParakeetInstalledModel {
    ParakeetInstalledModel(
      name: ParakeetModelInstaller.modelName,
      repository: ParakeetModelInstaller.repository,
      revision: ParakeetModelInstaller.sourceRevision,
      files: [
        ParakeetInstalledModelFile(
          relativePath: "vocab.json",
          sha256: Self.sha256(Data("vocab".utf8)),
          sizeBytes: 5)
      ],
      sizeBytes: 5,
      installedAt: Date(timeIntervalSince1970: 1_718_000_000),
      localModelPath: nil
    )
  }

  private static func makeApplicationSupportDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dspeech-parakeet-\(UUID().uuidString)", isDirectory: true)
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

private final class InMemoryParakeetModelStateStorage: ParakeetModelStateStorage,
  @unchecked Sendable
{
  var state: ParakeetModelInstallState = .absent
  var savedStates: [ParakeetModelInstallState] = []

  func loadState() -> ParakeetModelInstallState { state }

  func saveState(_ state: ParakeetModelInstallState) {
    self.state = state
    savedStates.append(state)
  }
}

private final class FakeParakeetModelFileDownloader: ParakeetModelFileDownloading,
  @unchecked Sendable
{
  private let provider: @Sendable (String) -> Data
  private(set) var downloadedRelativePaths: [String] = []

  init(provider: @escaping @Sendable (String) -> Data) {
    self.provider = provider
  }

  func download(from sourceURL: URL, to destinationURL: URL) async throws {
    let modelRelativePath = Self.modelRelativePath(from: destinationURL)
    let data = provider(modelRelativePath)
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: destinationURL, options: .atomic)
    downloadedRelativePaths.append(modelRelativePath)
    #expect(sourceURL.absoluteString.contains(ParakeetModelInstaller.sourceRevision))
  }

  private static func modelRelativePath(from url: URL) -> String {
    let components = url.pathComponents
    guard
      let index = components.lastIndex(of: ParakeetModelInstaller.modelFolderName),
      index + 1 < components.endIndex
    else {
      return url.lastPathComponent
    }
    return components[(index + 1)...].joined(separator: "/")
  }
}
