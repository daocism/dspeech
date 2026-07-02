import AVFoundation
import CryptoKit
import FluidAudio
import Foundation
import Testing

@testable import Dspeech

struct SpeakerModelPackInstallerTests {
  private static let segmentationFixturePath = "pyannote_segmentation.mlmodelc/model.mil"
  private static let embeddingFixturePath = "wespeaker_v2.mlmodelc/model.mil"

  @Test func productionManifestPinsFluidAudioModelFiles() {
    let manifest = Dictionary(
      uniqueKeysWithValues: SpeakerModelPackInstaller.expectedModelFileManifest.map {
        ($0.relativePath, $0.sha256)
      })

    #expect(manifest.count == 10)
    #expect(
      manifest["pyannote_segmentation.mlmodelc/analytics/coremldata.bin"]
        == "b379db0541b35344a34bb7540783ae704c11599bbed5aa8bbbda11c20ad215ee"
    )
    #expect(
      manifest["pyannote_segmentation.mlmodelc/coremldata.bin"]
        == "4a450ea1b053b9eb7eef0cab6971018076600840c7e246d064e7c5387f456c98"
    )
    #expect(
      manifest["pyannote_segmentation.mlmodelc/metadata.json"]
        == "44e1fa36d6abafacf688beccad99f7569394248d8bb41545829997c67668c08c"
    )
    #expect(
      manifest["pyannote_segmentation.mlmodelc/model.mil"]
        == "97f2dec6f83e80bf4247b98e13c2dde19f92c05820ef08068bbf554488d70bdd"
    )
    #expect(
      manifest["pyannote_segmentation.mlmodelc/weights/weight.bin"]
        == "0266f4ad4d843ecf31ef9220ad6b80616b3ec64a4404b64f3ea0371554e236ec"
    )
    #expect(
      manifest["wespeaker_v2.mlmodelc/analytics/coremldata.bin"]
        == "d2b1fcde6121aea3ff0e14c1dc50d09dacb0314a2e89156353c31804230a422f"
    )
    #expect(
      manifest["wespeaker_v2.mlmodelc/coremldata.bin"]
        == "6feb2472a71fa9d8a84020c85206138a4f6261c565c9884bf518d59dd5838da7"
    )
    #expect(
      manifest["wespeaker_v2.mlmodelc/metadata.json"]
        == "ddc4858b4051254098015cd0b97080149839d697faf7b036f933190e70b26758"
    )
    #expect(
      manifest["wespeaker_v2.mlmodelc/model.mil"]
        == "2850f775d6ba659f01f616fed77ce6a45a25de3eb7e4bf3a4b07b658be4e13dd"
    )
    #expect(
      manifest["wespeaker_v2.mlmodelc/weights/weight.bin"]
        == "34004f6798d35cad7071e2fdc67e63faaa782f53697e1cb49bcb452cf81ae151"
    )
  }

  @Test func productionManifestPinsSourceRevisionAndExpectedPackSize() {
    #expect(
      SpeakerModelPackInstaller.sourceRevision == "1ed7a662fdc7109e36d822db793ee6eebdaf8594"
    )
    #expect(SpeakerModelPackInstaller.expectedPackSizeBytes == 13_720_676)
  }

  @Test func freeSpacePreflightRequiresTwiceThePinnedPackSize() throws {
    do {
      try SpeakerModelPackInstaller.preflightSufficientFreeSpace(
        availableBytes: SpeakerModelPackInstaller.expectedPackSizeBytes * 2 - 1,
        expectedPackSizeBytes: SpeakerModelPackInstaller.expectedPackSizeBytes
      )
      Issue.record("expected insufficient disk space")
    } catch let error as ModelPackInstallError {
      #expect(
        error
          == .insufficientDiskSpace(
            requiredBytes: SpeakerModelPackInstaller.expectedPackSizeBytes * 2,
            availableBytes: SpeakerModelPackInstaller.expectedPackSizeBytes * 2 - 1
          )
      )
    } catch {
      Issue.record("expected ModelPackInstallError, got \(error)")
    }
  }

  @Test func freeSpacePreflightAcceptsAtLeastTwiceThePinnedPackSize() throws {
    try SpeakerModelPackInstaller.preflightSufficientFreeSpace(
      availableBytes: SpeakerModelPackInstaller.expectedPackSizeBytes * 2,
      expectedPackSizeBytes: SpeakerModelPackInstaller.expectedPackSizeBytes
    )
  }

  @Test func verifierAcceptsExactManifestBytes() throws {
    let contents = Self.validFixtureContents()
    let root = try Self.makeFixture(contents)
    defer { Self.removeFixture(root) }

    let verified = try SpeakerModelPackInstaller.verifyModelPack(
      at: root,
      manifest: Self.manifest(for: contents)
    )

    let expectedSize = contents.values.reduce(0) { $0 + $1.count }
    #expect(verified.sizeBytes == Int64(expectedSize))
    #expect(verified.checksumSHA256 == Self.packChecksum(for: contents))
  }

  @Test func verifierRejectsChangedBytesWithSameFileNamesAndSizes() throws {
    let original = Self.validFixtureContents()
    let root = try Self.makeFixture(original)
    defer { Self.removeFixture(root) }

    try Self.bytes("SEGM").write(
      to: root.appendingPathComponent(Self.segmentationFixturePath, isDirectory: false),
      options: .atomic
    )

    do {
      _ = try SpeakerModelPackInstaller.verifyModelPack(
        at: root,
        manifest: Self.manifest(for: original)
      )
      Issue.record("expected checksum mismatch")
    } catch let error as ModelPackInstallError {
      guard
        case .integrityChecksumMismatch(let relativePath, let expectedSHA256, let actualSHA256) =
          error
      else {
        Issue.record("expected checksum mismatch, got \(error)")
        return
      }
      #expect(relativePath == Self.segmentationFixturePath)
      #expect(expectedSHA256 == Self.sha256(Self.bytes("segm")))
      #expect(actualSHA256 == Self.sha256(Self.bytes("SEGM")))
    } catch {
      Issue.record("expected ModelPackInstallError, got \(error)")
    }
  }

  @Test func verifierRejectsMissingExpectedFile() throws {
    let contents = [
      Self.segmentationFixturePath: Self.bytes("segm")
    ]
    let root = try Self.makeFixture(contents)
    defer { Self.removeFixture(root) }

    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(SpeakerModelPackInstaller.embeddingFile, isDirectory: true),
      withIntermediateDirectories: true
    )

    do {
      _ = try SpeakerModelPackInstaller.verifyModelPack(
        at: root,
        manifest: [
          SpeakerModelPackInstaller.ExpectedModelFile(
            relativePath: Self.segmentationFixturePath,
            sha256: Self.sha256(Self.bytes("segm"))
          ),
          SpeakerModelPackInstaller.ExpectedModelFile(
            relativePath: Self.embeddingFixturePath,
            sha256: Self.sha256(Self.bytes("spkr"))
          ),
        ]
      )
      Issue.record("expected missing file integrity error")
    } catch let error as ModelPackInstallError {
      #expect(error == .integrityExpectedFileMissing(Self.embeddingFixturePath))
    } catch {
      Issue.record("expected ModelPackInstallError, got \(error)")
    }
  }

  @Test func verifierRejectsUnexpectedRegularFile() throws {
    let contents = Self.validFixtureContents()
    let root = try Self.makeFixture(contents)
    defer { Self.removeFixture(root) }

    let unexpectedPath = "wespeaker_v2.mlmodelc/unexpected.bin"
    try Self.bytes("extra").write(
      to: root.appendingPathComponent(unexpectedPath, isDirectory: false),
      options: .atomic
    )

    do {
      _ = try SpeakerModelPackInstaller.verifyModelPack(
        at: root,
        manifest: Self.manifest(for: contents)
      )
      Issue.record("expected unexpected file integrity error")
    } catch let error as ModelPackInstallError {
      #expect(error == .integrityUnexpectedFile(unexpectedPath))
    } catch {
      Issue.record("expected ModelPackInstallError, got \(error)")
    }
  }

  @Test func uninstallRemovesLocalModelDirectory() throws {
    let root = try Self.makeFixture(Self.validFixtureContents())
    defer { Self.removeFixture(root) }
    let pack = Self.installedPack(localModelPath: root.path)

    try SpeakerModelPackInstaller.uninstall(pack)

    #expect(!FileManager.default.fileExists(atPath: root.path))
  }

  @Test func instanceUninstallDeletesPersistedPilotProfiles() throws {
    let root = try Self.makeFixture(Self.validFixtureContents())
    defer { Self.removeFixture(root) }
    let suiteName = "dspeech.tests.modelpack.uninstall.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let profileStoreURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("dspeech-voice-profiles-\(UUID().uuidString)", isDirectory: false)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      if FileManager.default.fileExists(atPath: profileStoreURL.path) {
        try? FileManager.default.removeItem(at: profileStoreURL)
      }
    }
    let storage = UserDefaultsVoiceFilterStorage(
      defaults: defaults,
      profileStoreURL: profileStoreURL
    )
    storage.saveProfiles([
      PilotVoiceProfile(
        label: "Captain",
        voicePrint: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.9),
        enrolledAt: Date(timeIntervalSince1970: 0)
      )
    ])
    let installer = SpeakerModelPackInstaller(voiceFilterStorage: storage)
    let pack = Self.installedPack(localModelPath: root.path)

    try installer.uninstall(pack)

    #expect(storage.loadProfiles().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }

  @Test func uninstallMissingLocalModelDirectoryIsIdempotent() throws {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("dspeech-missing-modelpack-\(UUID().uuidString)", isDirectory: true)
    let pack = Self.installedPack(localModelPath: missing.path)

    try SpeakerModelPackInstaller.uninstall(pack)

    #expect(!FileManager.default.fileExists(atPath: missing.path))
  }

  private static func validFixtureContents() -> [String: Data] {
    [
      Self.segmentationFixturePath: Self.bytes("segm"),
      Self.embeddingFixturePath: Self.bytes("spkr"),
    ]
  }

  private static func manifest(for contents: [String: Data]) -> [SpeakerModelPackInstaller
    .ExpectedModelFile]
  {
    contents
      .map {
        SpeakerModelPackInstaller.ExpectedModelFile(
          relativePath: $0.key, sha256: Self.sha256($0.value))
      }
      .sorted { $0.relativePath < $1.relativePath }
  }

  private static func makeFixture(_ contents: [String: Data]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("dspeech-modelpack-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (relativePath, data) in contents {
      let fileURL = root.appendingPathComponent(relativePath, isDirectory: false)
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: fileURL, options: .atomic)
    }
    return root
  }

  private static func removeFixture(_ root: URL) {
    do {
      if FileManager.default.fileExists(atPath: root.path) {
        try FileManager.default.removeItem(at: root)
      }
    } catch {
      Issue.record("failed to remove fixture \(root.path): \(error)")
    }
  }

  private static func installedPack(localModelPath: String) -> InstalledModelPack {
    InstalledModelPack(
      identifier: SpeakerModelPackInstaller.packIdentifier,
      version: SpeakerModelPackInstaller.packVersion,
      embeddingDimension: SpeakerModelPackInstaller.embeddingDimension,
      checksumSHA256: "fixture",
      source: SpeakerModelPackInstaller.source,
      sizeBytes: 1,
      installedAt: Date(timeIntervalSince1970: 0),
      localModelPath: localModelPath
    )
  }

  private static func bytes(_ string: String) -> Data {
    Data(string.utf8)
  }

  private static func packChecksum(for contents: [String: Data]) -> String {
    var hasher = SHA256()
    for (_, data) in contents.sorted(by: { $0.key < $1.key }) {
      let digest = SHA256.hash(data: data)
      hasher.update(data: digest.withUnsafeBytes { Data($0) })
    }
    return Self.hexDigest(hasher.finalize())
  }

  private static func sha256(_ data: Data) -> String {
    Self.hexDigest(SHA256.hash(data: data))
  }

  private static func hexDigest(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}

@MainActor
struct ModelPackAcquisitionControllerTests {
  @Test func acceptsProgressAndCompletionForCurrentAttempt() async {
    let installer = ScriptedModelPackInstaller()
    var persisted: [ModelPackState] = []
    let controller = ModelPackAcquisitionController(
      initialState: .absent,
      installer: installer
    ) { state in
      persisted.append(state)
    }

    controller.startDownload()
    #expect(await Self.waitForAttemptCount(1, installer: installer))

    await installer.emitProgress(
      ModelPackAcquisition(phase: .downloading, fractionComplete: 0.35),
      at: 0
    )
    #expect(
      await Self.wait(for: {
        guard case .acquiring(let acquisition) = controller.state else { return false }
        return acquisition.percentComplete == 35
      })
    )

    await installer.complete(Self.pack("current"), at: 0)
    #expect(
      await Self.wait(for: {
        guard case .installed(let pack) = controller.state else { return false }
        return pack.checksumSHA256 == "current"
      })
    )
    #expect(persisted.last == controller.state)
  }

  @Test func lateProgressAndCompletionAfterCancelCannotMutateAbsentState() async {
    let installer = ScriptedModelPackInstaller()
    let controller = ModelPackAcquisitionController(initialState: .absent, installer: installer)

    controller.startDownload()
    #expect(await Self.waitForAttemptCount(1, installer: installer))
    controller.cancelDownload()

    await installer.emitProgress(
      ModelPackAcquisition(phase: .downloading, fractionComplete: 0.88),
      at: 0
    )
    await Self.drainMainActorQueue()
    #expect(controller.state == .absent)

    await installer.complete(Self.pack("stale"), at: 0)
    await Self.drainMainActorQueue()
    #expect(controller.state == .absent)
  }

  @Test func retryIgnoresOldAttemptProgressAndCompletion() async {
    let installer = ScriptedModelPackInstaller()
    let controller = ModelPackAcquisitionController(initialState: .absent, installer: installer)

    controller.startDownload()
    #expect(await Self.waitForAttemptCount(1, installer: installer))
    controller.startDownload()
    #expect(await Self.waitForAttemptCount(2, installer: installer))

    await installer.emitProgress(
      ModelPackAcquisition(phase: .downloading, fractionComplete: 0.99),
      at: 0
    )
    await Self.drainMainActorQueue()
    guard case .acquiring(let initialRetryProgress) = controller.state else {
      Issue.record("expected acquiring state after retry")
      return
    }
    #expect(initialRetryProgress.percentComplete == 0)

    await installer.emitProgress(
      ModelPackAcquisition(phase: .importing, fractionComplete: 0.42),
      at: 1
    )
    #expect(
      await Self.wait(for: {
        guard case .acquiring(let acquisition) = controller.state else { return false }
        return acquisition.phase == .importing && acquisition.percentComplete == 42
      })
    )

    await installer.complete(Self.pack("old"), at: 0)
    await Self.drainMainActorQueue()
    guard case .acquiring(let stillCurrentProgress) = controller.state else {
      Issue.record("old completion should not install stale pack")
      return
    }
    #expect(stillCurrentProgress.phase == .importing)
    #expect(stillCurrentProgress.percentComplete == 42)

    await installer.complete(Self.pack("new"), at: 1)
    #expect(
      await Self.wait(for: {
        guard case .installed(let pack) = controller.state else { return false }
        return pack.checksumSHA256 == "new"
      })
    )
  }

  @Test func lateFailureAfterRetryCannotOverwriteCurrentAttempt() async {
    let installer = ScriptedModelPackInstaller()
    let controller = ModelPackAcquisitionController(initialState: .absent, installer: installer)

    controller.startDownload()
    #expect(await Self.waitForAttemptCount(1, installer: installer))
    controller.startDownload()
    #expect(await Self.waitForAttemptCount(2, installer: installer))

    await installer.fail(URLError(.notConnectedToInternet), at: 0)
    await Self.drainMainActorQueue()
    guard case .acquiring = controller.state else {
      Issue.record("stale failure should leave the current retry active")
      return
    }

    await installer.fail(URLError(.notConnectedToInternet), at: 1)
    #expect(
      await Self.wait(for: {
        guard case .failed(let failure) = controller.state else { return false }
        return failure.kind == .network && failure.isRetryable
      })
    )
  }

  private static func wait(
    for predicate: @MainActor () -> Bool,
    timeout: Duration = .seconds(5)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return predicate()
  }

  private static func waitForAttemptCount(
    _ count: Int,
    installer: ScriptedModelPackInstaller,
    timeout: Duration = .seconds(5)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await installer.attemptCount() == count { return true }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await installer.attemptCount() == count
  }

  private static func drainMainActorQueue() async {
    for _ in 0..<20 { await Task.yield() }
  }

  private static func pack(_ checksum: String) -> InstalledModelPack {
    InstalledModelPack(
      identifier: SpeakerModelPackInstaller.packIdentifier,
      version: SpeakerModelPackInstaller.packVersion,
      embeddingDimension: SpeakerModelPackInstaller.embeddingDimension,
      checksumSHA256: checksum,
      source: SpeakerModelPackInstaller.source,
      sizeBytes: 1024,
      installedAt: Date(timeIntervalSince1970: 0),
      localModelPath: "/tmp/\(checksum)"
    )
  }
}

private actor ScriptedModelPackInstaller: ModelPackInstalling {
  private struct Attempt {
    let progress: @Sendable (ModelPackAcquisition) -> Void
    let continuation: CheckedContinuation<InstalledModelPack, any Error>
  }

  private var attempts: [Attempt] = []

  func install(
    progress: @escaping @Sendable (ModelPackAcquisition) -> Void
  ) async throws -> InstalledModelPack {
    try await withCheckedThrowingContinuation { continuation in
      attempts.append(Attempt(progress: progress, continuation: continuation))
    }
  }

  func attemptCount() -> Int {
    attempts.count
  }

  func emitProgress(_ acquisition: ModelPackAcquisition, at index: Int) {
    guard attempts.indices.contains(index) else { return }
    attempts[index].progress(acquisition)
  }

  func complete(_ pack: InstalledModelPack, at index: Int) {
    guard attempts.indices.contains(index) else { return }
    attempts[index].continuation.resume(returning: pack)
  }

  func fail(_ error: Error, at index: Int) {
    guard attempts.indices.contains(index) else { return }
    attempts[index].continuation.resume(throwing: error)
  }
}
