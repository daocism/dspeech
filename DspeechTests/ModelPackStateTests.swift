import AVFoundation
import CryptoKit
import FluidAudio
import Foundation
import Testing

@testable import Dspeech

@Suite(.serialized)
struct SpeakerModelPackSourceTests {
  enum FixtureError: Error {
    case failure
  }

  @Test func overrideAbsentWhenInfoDictionaryNil() {
    #expect(SpeakerModelPackInstaller.registryBaseURLOverride(infoDictionary: nil) == nil)
  }

  @Test func overrideAbsentWhenKeyMissing() {
    #expect(
      SpeakerModelPackInstaller.registryBaseURLOverride(infoDictionary: ["other": "x"]) == nil)
  }

  @Test func overrideAbsentWhenEmptyOrWhitespace() {
    let key = SpeakerModelPackInstaller.registryBaseURLOverrideKey
    #expect(SpeakerModelPackInstaller.registryBaseURLOverride(infoDictionary: [key: ""]) == nil)
    #expect(
      SpeakerModelPackInstaller.registryBaseURLOverride(infoDictionary: [key: "   "]) == nil)
  }

  @Test func overrideAbsentWhenNotAString() {
    let key = SpeakerModelPackInstaller.registryBaseURLOverrideKey
    #expect(SpeakerModelPackInstaller.registryBaseURLOverride(infoDictionary: [key: 42]) == nil)
  }

  @Test func overrideUsedWhenPresent() {
    let key = SpeakerModelPackInstaller.registryBaseURLOverrideKey
    #expect(
      SpeakerModelPackInstaller.registryBaseURLOverride(
        infoDictionary: [key: " https://mirror.example/internal "])
        == "https://mirror.example/internal")
  }

  @Test func resolvedRegistrySourceIncludesConfiguredMirrorPinnedRepoAndRevision() {
    let key = SpeakerModelPackInstaller.registryBaseURLOverrideKey
    let mirror = "https://mirror.example/internal"

    #expect(
      SpeakerModelPackInstaller.resolvedRegistrySource(infoDictionary: [key: mirror])
        == "\(mirror)/\(SpeakerModelPackInstaller.source)/resolve/\(SpeakerModelPackInstaller.sourceRevision)"
    )
  }

  @Test func pinnedDownloadURLUsesImmutableRevisionInsteadOfMain() throws {
    let key = SpeakerModelPackInstaller.registryBaseURLOverrideKey
    let mirror = "https://mirror.example/internal"

    let url = try SpeakerModelPackInstaller.pinnedDownloadURL(
      relativePath: "pyannote_segmentation.mlmodelc/model.mil",
      infoDictionary: [key: mirror]
    )

    #expect(
      url.absoluteString
        == "\(mirror)/\(SpeakerModelPackInstaller.source)/resolve/\(SpeakerModelPackInstaller.sourceRevision)/pyannote_segmentation.mlmodelc/model.mil"
    )
    #expect(!url.absoluteString.contains("/resolve/main/"))
  }

  @Test func scopedRegistryOverrideRestoresOriginalAfterOperation() async throws {
    let original = ModelRegistry.baseURL
    defer { ModelRegistry.baseURL = original }
    let key = SpeakerModelPackInstaller.registryBaseURLOverrideKey
    let mirror = "https://mirror.example/internal"

    let observed = try await SpeakerModelPackInstaller.withConfiguredRegistryBaseURL(
      infoDictionary: [key: mirror]
    ) {
      #expect(ModelRegistry.baseURL == mirror)
      return ModelRegistry.baseURL
    }

    #expect(observed == mirror)
    #expect(ModelRegistry.baseURL == original)
  }

  @Test func scopedRegistryOverrideRestoresOriginalAfterThrownOperation() async throws {
    let original = ModelRegistry.baseURL
    defer { ModelRegistry.baseURL = original }
    let key = SpeakerModelPackInstaller.registryBaseURLOverrideKey
    let mirror = "https://mirror.example/internal"

    do {
      _ = try await SpeakerModelPackInstaller.withConfiguredRegistryBaseURL(
        infoDictionary: [key: mirror]
      ) {
        #expect(ModelRegistry.baseURL == mirror)
        throw FixtureError.failure
      }
      Issue.record("expected scoped operation to throw")
    } catch FixtureError.failure {
      #expect(ModelRegistry.baseURL == original)
    } catch {
      Issue.record("expected FixtureError.failure, got \(error)")
    }
  }

  @Test func scopedRegistryOverrideSerializesConcurrentOperations() async throws {
    let original = ModelRegistry.baseURL
    defer { ModelRegistry.baseURL = original }
    let key = SpeakerModelPackInstaller.registryBaseURLOverrideKey
    let firstMirror = "https://mirror-one.example/internal"
    let secondMirror = "https://mirror-two.example/internal"

    async let first = SpeakerModelPackInstaller.withConfiguredRegistryBaseURL(
      infoDictionary: [key: firstMirror]
    ) {
      try await Task.sleep(nanoseconds: 100_000_000)
      #expect(ModelRegistry.baseURL == firstMirror)
      return ModelRegistry.baseURL
    }
    async let second = SpeakerModelPackInstaller.withConfiguredRegistryBaseURL(
      infoDictionary: [key: secondMirror]
    ) {
      #expect(ModelRegistry.baseURL == secondMirror)
      return ModelRegistry.baseURL
    }

    let observed = try await [first, second]
    #expect(Set(observed) == [firstMirror, secondMirror])
    #expect(ModelRegistry.baseURL == original)
  }

  @Test func scopedRegistryOverrideCancelledWaiterDoesNotEnterOrHoldGate() async throws {
    let original = ModelRegistry.baseURL
    defer { ModelRegistry.baseURL = original }
    let key = SpeakerModelPackInstaller.registryBaseURLOverrideKey
    let firstMirror = "https://mirror-one.example/internal"
    let secondMirror = "https://mirror-two.example/internal"
    let thirdMirror = "https://mirror-three.example/internal"
    let hold = RegistryGateHold()

    let first = Task {
      try await SpeakerModelPackInstaller.withConfiguredRegistryBaseURL(
        infoDictionary: [key: firstMirror]
      ) {
        await hold.markEntered()
        await hold.waitForRelease()
        return ModelRegistry.baseURL
      }
    }
    #expect(await hold.waitUntilEntered())

    let second = Task {
      try await SpeakerModelPackInstaller.withConfiguredRegistryBaseURL(
        infoDictionary: [key: secondMirror]
      ) {
        Issue.record("cancelled waiter must not enter the scoped registry override")
        return ModelRegistry.baseURL
      }
    }
    for _ in 0..<50 { await Task.yield() }
    second.cancel()
    await hold.release()

    #expect(try await first.value == firstMirror)
    do {
      _ = try await second.value
      Issue.record("expected cancelled waiter to throw CancellationError")
    } catch is CancellationError {
      #expect(ModelRegistry.baseURL == original)
    } catch {
      Issue.record("expected CancellationError, got \(error)")
    }

    let third = try await SpeakerModelPackInstaller.withConfiguredRegistryBaseURL(
      infoDictionary: [key: thirdMirror]
    ) {
      #expect(ModelRegistry.baseURL == thirdMirror)
      return ModelRegistry.baseURL
    }
    #expect(third == thirdMirror)
    #expect(ModelRegistry.baseURL == original)
  }
}

private actor RegistryGateHold {
  private var entered = false
  private var released = false
  private var enteredWaiters: [CheckedContinuation<Bool, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func markEntered() {
    entered = true
    let waiters = enteredWaiters
    enteredWaiters.removeAll()
    for waiter in waiters { waiter.resume(returning: true) }
  }

  func waitUntilEntered() async -> Bool {
    if entered { return true }
    return await withCheckedContinuation { continuation in
      enteredWaiters.append(continuation)
    }
  }

  func waitForRelease() async {
    if released { return }
    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }
  }

  func release() {
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}

struct ModelPackStateStorageTests {
  private func makeStore() -> (UserDefaultsModelPackStateStorage, () -> Void) {
    let suiteName = "dspeech.tests.modelpack.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let applicationSupportDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dspeech-app-support-\(UUID().uuidString)", isDirectory: true)
    let cleanup = {
      defaults.removePersistentDomain(forName: suiteName)
      if FileManager.default.fileExists(atPath: applicationSupportDirectory.path) {
        try? FileManager.default.removeItem(at: applicationSupportDirectory)
      }
    }
    return (
      UserDefaultsModelPackStateStorage(
        defaults: defaults,
        applicationSupportDirectory: applicationSupportDirectory
      ),
      cleanup
    )
  }

  private static func pack(localModelPath: String? = nil) -> InstalledModelPack {
    InstalledModelPack(
      identifier: "fluidaudio-speaker-256",
      version: "1.0.0",
      embeddingDimension: 256,
      checksumSHA256: String(repeating: "a", count: 64),
      source: "https://mirror.invalid/voice-filter",
      sizeBytes: 12_345_678,
      installedAt: Date(timeIntervalSince1970: 748_137_600),
      localModelPath: localModelPath
    )
  }

  @Test func roundTripAbsent() {
    let (store, cleanup) = makeStore()
    defer { cleanup() }
    store.saveState(.absent)
    #expect(store.loadState() == .absent)
  }

  @Test func roundTripInstalled() {
    let (store, cleanup) = makeStore()
    defer { cleanup() }
    store.saveState(.installed(Self.pack()))
    #expect(store.loadState() == .installed(Self.pack()))
  }

  @Test func savePersistsModelPathRelativeToApplicationSupportAndLoadResolvesIt() throws {
    let suiteName = "dspeech.tests.modelpack.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let applicationSupportDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dspeech-app-support-\(UUID().uuidString)", isDirectory: true)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      if FileManager.default.fileExists(atPath: applicationSupportDirectory.path) {
        try? FileManager.default.removeItem(at: applicationSupportDirectory)
      }
    }
    let store = UserDefaultsModelPackStateStorage(
      defaults: defaults,
      applicationSupportDirectory: applicationSupportDirectory
    )
    let relativePath = "FluidAudio/Models/speaker-diarization-coreml"
    let absolutePath =
      applicationSupportDirectory
      .appendingPathComponent(relativePath, isDirectory: true)
      .path
    let pack = Self.pack(localModelPath: absolutePath)

    store.saveState(.installed(pack))

    let data = try #require(defaults.data(forKey: UserDefaultsModelPackStateStorage.stateKey))
    guard
      case .installed(let persistedPack) = try JSONDecoder().decode(ModelPackState.self, from: data)
    else {
      Issue.record("expected raw persisted installed state")
      return
    }
    #expect(persistedPack.localModelPath == relativePath)
    #expect(store.loadState() == .installed(pack))
  }

  @Test func legacyAbsoluteModelPathMigratesToCurrentApplicationSupportContainer() throws {
    let suiteName = "dspeech.tests.modelpack.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let oldApplicationSupport = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "old-container-\(UUID().uuidString)/Application Support",
        isDirectory: true
      )
    let newApplicationSupport = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "new-container-\(UUID().uuidString)/Application Support",
        isDirectory: true
      )
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      for url in [oldApplicationSupport, newApplicationSupport] {
        let container = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: container.path) {
          try? FileManager.default.removeItem(at: container)
        }
      }
    }
    let relativePath = "FluidAudio/Models/speaker-diarization-coreml"
    let legacyAbsolutePath =
      oldApplicationSupport
      .appendingPathComponent(relativePath, isDirectory: true)
      .path
    let legacyState = ModelPackState.installed(Self.pack(localModelPath: legacyAbsolutePath))
    defaults.set(
      try JSONEncoder().encode(legacyState),
      forKey: UserDefaultsModelPackStateStorage.stateKey
    )
    let store = UserDefaultsModelPackStateStorage(
      defaults: defaults,
      applicationSupportDirectory: newApplicationSupport
    )

    let loaded = store.loadState()

    let expectedResolvedPath =
      newApplicationSupport
      .appendingPathComponent(relativePath, isDirectory: true)
      .path
    #expect(loaded.installedPack?.localModelPath == expectedResolvedPath)
    let data = try #require(defaults.data(forKey: UserDefaultsModelPackStateStorage.stateKey))
    guard
      case .installed(let migratedPack) = try JSONDecoder().decode(ModelPackState.self, from: data)
    else {
      Issue.record("expected migrated raw installed state")
      return
    }
    #expect(migratedPack.localModelPath == relativePath)
  }

  @Test func roundTripFailed() {
    let (store, cleanup) = makeStore()
    defer { cleanup() }
    let failure = ModelPackFailure(
      kind: .checksum,
      userSafeReason: "Проверка контрольной суммы не прошла.",
      isRetryable: true
    )
    store.saveState(.failed(failure))
    #expect(store.loadState() == .failed(failure))
  }

  @Test func roundTripDisabled() {
    let (store, cleanup) = makeStore()
    defer { cleanup() }
    store.saveState(.disabled(Self.pack()))
    #expect(store.loadState() == .disabled(Self.pack()))
  }

  @Test func acquiringRecoversToAbsentOnColdStart() {
    let (store, cleanup) = makeStore()
    defer { cleanup() }
    store.saveState(.acquiring(ModelPackAcquisition(phase: .downloading, fractionComplete: 0.4)))
    #expect(store.loadState() == .absent)
  }

  @Test func missingDataLoadsAbsent() {
    let (store, cleanup) = makeStore()
    defer { cleanup() }
    #expect(store.loadState() == .absent)
  }

  @Test func corruptDataLoadsFailedState() {
    let suiteName = "dspeech.tests.modelpack.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(
      Data([0x00, 0x01, 0x02, 0x03]), forKey: UserDefaultsModelPackStateStorage.stateKey)
    let store = UserDefaultsModelPackStateStorage(defaults: defaults)
    guard case .failed(let failure) = store.loadState() else {
      Issue.record("expected corrupt persisted model-pack state to load as failed")
      return
    }
    #expect(failure.kind == .corruptState)
    #expect(failure.isRetryable == false)
    #expect(!failure.userSafeReason.isEmpty)
  }

  @Test func unknownLaunchArgumentStringLoadsFailedState() {
    let suiteName = "dspeech.tests.modelpack.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("not-a-model-pack-state", forKey: UserDefaultsModelPackStateStorage.stateKey)
    let store = UserDefaultsModelPackStateStorage(defaults: defaults)
    guard case .failed(let failure) = store.loadState() else {
      Issue.record("expected unknown persisted string to load as failed")
      return
    }
    #expect(failure.kind == .corruptState)
  }

  @Test func launchArgumentFailedRetryableLoadsFailedState() {
    let suiteName = "dspeech.tests.modelpack.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("failedRetryable", forKey: UserDefaultsModelPackStateStorage.stateKey)
    let store = UserDefaultsModelPackStateStorage(defaults: defaults)
    let state = store.loadState()
    guard case .failed(let failure) = state else {
      Issue.record("expected failed state from launch argument, got \(state)")
      return
    }
    #expect(failure.isRetryable)
  }

  @Test func launchArgumentAcquiringHalfLoadsAcquiringProgress() {
    let suiteName = "dspeech.tests.modelpack.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("acquiringHalf", forKey: UserDefaultsModelPackStateStorage.stateKey)
    let store = UserDefaultsModelPackStateStorage(defaults: defaults)
    let state = store.loadState()
    guard case .acquiring(let acquisition) = state else {
      Issue.record("expected acquiring state from launch argument, got \(state)")
      return
    }
    #expect(acquisition.percentComplete == 42)
  }
}

struct ModelPackDownloadFailureTests {
  @Test func integrityInstallErrorsProduceChecksumFailure() {
    let errors: [ModelPackInstallError] = [
      .integrityExpectedFileMissing("model.bin"),
      .integrityUnexpectedFile("extra.bin"),
      .integrityChecksumMismatch(
        relativePath: "model.bin", expectedSHA256: "expected", actualSHA256: "actual"),
      .integrityFileUnreadable("model.bin"),
      .integrityManifestEmpty,
    ]

    for error in errors {
      let failure = modelPackDownloadFailure(for: error)
      #expect(failure.kind == .checksum)
      #expect(!failure.isRetryable)
      #expect(failure.userSafeReason.contains("changed upstream"))
      #expect(!failure.userSafeReason.contains("network"))
    }
  }

  @Test func networkDownloadErrorsProduceNetworkFailure() {
    let failure = modelPackDownloadFailure(for: URLError(.notConnectedToInternet))

    #expect(failure.kind == .network)
    #expect(failure.isRetryable)
    #expect(failure.userSafeReason.contains("network"))
  }

  @Test func diskFullInstallErrorsProduceDiskFailure() {
    let failures = [
      modelPackDownloadFailure(
        for: ModelPackInstallError.insufficientDiskSpace(requiredBytes: 200, availableBytes: 99)),
      modelPackDownloadFailure(for: CocoaError(.fileWriteOutOfSpace)),
      modelPackDownloadFailure(for: POSIXError(.ENOSPC)),
    ]

    for failure in failures {
      #expect(failure.kind == .disk)
      #expect(failure.isRetryable)
      #expect(failure.userSafeReason.contains("storage"))
    }
  }

  @Test func nonIntegrityNonNetworkInstallErrorsProduceUnknownFailure() {
    let failure = modelPackDownloadFailure(for: ModelPackInstallError.filesMissingAfterDownload)

    #expect(failure.kind == .unknown)
    #expect(!failure.isRetryable)
    #expect(!failure.userSafeReason.contains("network"))
  }

  @Test func deleteErrorsProduceDiskFailure() {
    let failure = modelPackDeleteFailure(for: CocoaError(.fileWriteNoPermission))

    #expect(failure.kind == .disk)
    #expect(!failure.isRetryable)
    #expect(failure.userSafeReason.contains("delete"))
  }
}
