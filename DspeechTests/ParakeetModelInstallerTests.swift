import CryptoKit
import Foundation
import PropertyBased
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

  // why: C2 — a specifically-offline device maps to `.offline` (distinct copy), NOT the generic
  // `.network` failure, so the pilot is told to reconnect rather than "check the connection".
  @Test func offlineErrorsMapToOfflineFailureTaxonomyDistinctFromNetwork() {
    for code in [
      URLError.Code.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
    ] {
      let failure = parakeetModelDownloadFailure(for: URLError(code))
      #expect(failure.kind == .offline)
      #expect(failure.isRetryable)
    }
    let generic = parakeetModelDownloadFailure(for: URLError(.badServerResponse))
    #expect(generic.kind == .network)
    let offline = parakeetModelDownloadFailure(for: URLError(.notConnectedToInternet))
    #expect(offline.userSafeReason != generic.userSafeReason)
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

// MARK: - F13 — PropertyBased state-machine properties (Parakeet installer)

// why: F13 — the Parakeet mirror of the WhisperKit property suite. Both installers share the same
// download-stage-verify engine (ModelInstallSupport.downloadAndStagePinnedModel), so the same
// state-machine invariants must hold: a terminal state matching the decisive fault, checksum-never-
// installed, no complete unverified model dir after a failure, and resume-converges-on-retry. NEW
// PropertyBased suite; the example-based tests above stay as-is. Every property carries a REACH gate
// so a green run can't be vacuous (vacuous-guard rule).

private enum ParakeetDownloadFault: Sendable, Equatable {
  case success
  case checksumMismatch
  case networkError
  case offline
  case cancel
}

// why: file-scope (not a @MainActor static) so the @Sendable generator `.map` closure can capture it.
private let parakeetFailureKinds: [ParakeetDownloadFault] = [
  .checksumMismatch, .networkError, .offline, .cancel,
]

@MainActor
private final class ParakeetInstallerReach {
  var installed = 0
  var checksum = 0
  var network = 0
  var offline = 0
  var cancel = 0
  var converged = 0
  var resumeSkipped = 0
}

private final class ProgrammableParakeetDownloader: ParakeetModelFileDownloading,
  @unchecked Sendable
{
  private let contents: [String: Data]
  private let faultByPath: [String: ParakeetDownloadFault]
  private(set) var attempted: [String] = []

  init(contents: [String: Data], faultByPath: [String: ParakeetDownloadFault]) {
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
      let index = components.lastIndex(of: ParakeetModelInstaller.modelFolderName),
      index + 1 < components.endIndex
    else {
      return url.lastPathComponent
    }
    return components[(index + 1)...].joined(separator: "/")
  }
}

@MainActor
struct ParakeetInstallerPropertyTests {
  private static let fileCount = 6

  private static func fixture() -> (
    files: [ParakeetModelInstaller.ExpectedModelFile], contents: [String: Data]
  ) {
    var files: [ParakeetModelInstaller.ExpectedModelFile] = []
    var contents: [String: Data] = [:]
    for index in 0..<fileCount {
      let relativePath = "encoder\(index).mlmodelc/weights/weight.bin"
      let data = Data("parakeet-pbt-fixture:\(index)".utf8)
      contents[relativePath] = data
      files.append(
        ParakeetModelInstaller.ExpectedModelFile(
          relativePath: relativePath,
          sizeBytes: Int64(data.count),
          expectedSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        ))
    }
    return (files, contents)
  }

  private static func makeApplicationSupportDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dspeech-parakeet-pbt-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func makeInstaller(
    _ storage: any ParakeetModelStateStorage,
    _ downloader: any ParakeetModelFileDownloading,
    _ appSupport: URL,
    _ files: [ParakeetModelInstaller.ExpectedModelFile]
  ) -> ParakeetModelInstaller {
    ParakeetModelInstaller(
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
      "FluidAudio/Models/parakeet-realtime-eou-120m-coreml/160ms", isDirectory: true)
  }

  private static func perFileFaultGenerator()
    -> Generator<ParakeetDownloadFault, some SendableSequenceType>
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
    -> Generator<ParakeetDownloadFault, some SendableSequenceType>
  {
    Gen.int(in: 0..<parakeetFailureKinds.count).map { parakeetFailureKinds[$0] }
  }

  @Test func terminalStateMatchesDecisiveFaultAndFailureLeavesNoModelFolder() async {
    let reach = ParakeetInstallerReach()
    await propertyCheck(
      count: 240, input: Self.perFileFaultGenerator().array(of: Self.fileCount)
    ) { faults in
      let appSupport = Self.makeApplicationSupportDirectory()
      defer { try? FileManager.default.removeItem(at: appSupport) }
      let (files, contents) = Self.fixture()
      let faultByPath = Dictionary(
        uniqueKeysWithValues: zip(files.map(\.relativePath), faults))
      let storage = PBTParakeetStateStorage()
      let downloader = ProgrammableParakeetDownloader(
        contents: contents, faultByPath: faultByPath)
      let installer = Self.makeInstaller(storage, downloader, appSupport, files)

      await installer.install()

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

      if case .failed = installer.state {
        #expect(installer.installedModelFolderURL == nil)
        #expect(!FileManager.default.fileExists(atPath: Self.finalFolder(appSupport).path))
      }
    }

    #expect(reach.installed > 0)
    #expect(reach.checksum > 0)
    #expect(reach.network > 0)
    #expect(reach.offline > 0)
    #expect(reach.cancel > 0)
  }

  @Test func retryAfterPartialConvergesAndSkipsStagedFiles() async {
    let reach = ParakeetInstallerReach()
    let input = zip(
      Gen.int(in: 0..<Self.fileCount),
      Self.failureKindGenerator()
    )
    await propertyCheck(count: 180, input: input) { failIndex, failKind in
      let appSupport = Self.makeApplicationSupportDirectory()
      defer { try? FileManager.default.removeItem(at: appSupport) }
      let (files, contents) = Self.fixture()
      var faults = [ParakeetDownloadFault](repeating: .success, count: files.count)
      faults[failIndex] = failKind
      let faultByPath = Dictionary(
        uniqueKeysWithValues: zip(files.map(\.relativePath), faults))
      let storage = PBTParakeetStateStorage()

      let firstDownloader = ProgrammableParakeetDownloader(
        contents: contents, faultByPath: faultByPath)
      await Self.makeInstaller(storage, firstDownloader, appSupport, files).install()
      guard case .failed = storage.state else {
        Issue.record("forced-fault install did not fail: \(storage.state)")
        return
      }

      let retryDownloader = ProgrammableParakeetDownloader(
        contents: contents, faultByPath: [:])
      await Self.makeInstaller(storage, retryDownloader, appSupport, files).install()
      guard case .installed = storage.state else {
        Issue.record("retry did not converge to installed: \(storage.state)")
        return
      }
      reach.converged += 1

      if failIndex > 0 {
        let staged = files[0..<failIndex].map(\.relativePath)
        #expect(staged.allSatisfy { !retryDownloader.attempted.contains($0) })
        #expect(retryDownloader.attempted.contains(files[failIndex].relativePath))
        reach.resumeSkipped += 1
      }
    }

    #expect(reach.converged > 0)
    #expect(reach.resumeSkipped > 0)
  }

  private static func expectFailed(
    _ state: ParakeetModelInstallState,
    kind: ParakeetModelInstallFailure.Kind,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    guard case .failed(let failure) = state else {
      Issue.record("expected .failed(\(kind)), got \(state)", sourceLocation: sourceLocation)
      return
    }
    #expect(failure.kind == kind, sourceLocation: sourceLocation)
  }
}

private final class PBTParakeetStateStorage: ParakeetModelStateStorage, @unchecked Sendable {
  var state: ParakeetModelInstallState = .absent

  func loadState() -> ParakeetModelInstallState { state }
  func saveState(_ state: ParakeetModelInstallState) { self.state = state }
}
