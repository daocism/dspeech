import AVFoundation
import CryptoKit
import FluidAudio
import Foundation
import Testing

@testable import Dspeech

struct VoiceFilterStorageTests {
  private func makeStore() -> (UserDefaultsVoiceFilterStorage, () -> Void) {
    let suiteName = "dspeech.tests.voicefilter.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let profileStoreURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("dspeech-voice-profiles-\(UUID().uuidString)", isDirectory: false)
    let cleanup = {
      defaults.removePersistentDomain(forName: suiteName)
      if FileManager.default.fileExists(atPath: profileStoreURL.path) {
        try? FileManager.default.removeItem(at: profileStoreURL)
      }
    }
    return (
      UserDefaultsVoiceFilterStorage(defaults: defaults, profileStoreURL: profileStoreURL),
      cleanup
    )
  }

  @Test func emptyDefaults() {
    let (store, cleanup) = makeStore()
    defer { cleanup() }
    #expect(store.loadProfiles().isEmpty)
    #expect(store.loadCallSign() == nil)
    #expect(store.loadEnabled() == false)
    #expect(store.loadGateConfig() == .default)
    #expect(store.loadSnapshot().issues.isEmpty)
  }

  @Test func profilesRoundTrip() {
    let (store, cleanup) = makeStore()
    defer { cleanup() }
    let profile = PilotVoiceProfile(
      label: "Captain",
      voicePrint: VoicePrintVector(values: [0.1, 0.2, 0.3, 0.4], quality: 0.83),
      enrolledAt: Date(timeIntervalSince1970: 748_137_600)
    )
    store.saveProfiles([profile])
    let loaded = store.loadProfiles()
    #expect(loaded.count == 1)
    #expect(loaded.first?.label == "Captain")
    #expect(loaded.first?.voicePrint.values == [0.1, 0.2, 0.3, 0.4])
  }

  @Test func profilesPersistToProtectedFileNotUserDefaults() throws {
    let suiteName = "dspeech.tests.voicefilter.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let profileStoreURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("dspeech-voice-profiles-\(UUID().uuidString)", isDirectory: false)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      if FileManager.default.fileExists(atPath: profileStoreURL.path) {
        try? FileManager.default.removeItem(at: profileStoreURL)
      }
    }
    let store = UserDefaultsVoiceFilterStorage(defaults: defaults, profileStoreURL: profileStoreURL)
    let profile = PilotVoiceProfile(
      label: "Captain",
      voicePrint: VoicePrintVector(values: [0.1, 0.2, 0.3, 0.4], quality: 0.83),
      enrolledAt: Date(timeIntervalSince1970: 748_137_600)
    )

    store.saveProfiles([profile])

    #expect(defaults.data(forKey: UserDefaultsVoiceFilterStorage.profilesKey) == nil)
    #expect(FileManager.default.fileExists(atPath: profileStoreURL.path))
    let resourceValues = try profileStoreURL.resourceValues(forKeys: [
      .isExcludedFromBackupKey,
      .fileProtectionKey,
    ])
    #expect(resourceValues.isExcludedFromBackup == true)
    // why: the Simulator does not implement Data Protection — the protection class is
    // stored but resourceValues reports it unreliably there. The equality assertion is
    // meaningful (and enforced) only on a physical device.
    #if os(iOS) && !targetEnvironment(simulator)
      #expect(resourceValues.fileProtection == .complete)
    #endif
  }

  @Test func legacyUserDefaultsProfilesMigrateToFileAndAreRemovedFromDefaults() throws {
    let suiteName = "dspeech.tests.voicefilter.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let profileStoreURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("dspeech-voice-profiles-\(UUID().uuidString)", isDirectory: false)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      if FileManager.default.fileExists(atPath: profileStoreURL.path) {
        try? FileManager.default.removeItem(at: profileStoreURL)
      }
    }
    let profile = PilotVoiceProfile(
      label: "Captain",
      voicePrint: VoicePrintVector(values: [0.1, 0.2, 0.3, 0.4], quality: 0.83),
      enrolledAt: Date(timeIntervalSince1970: 748_137_600)
    )
    let legacyData = try JSONEncoder().encode([profile])
    defaults.set(legacyData, forKey: UserDefaultsVoiceFilterStorage.profilesKey)
    let store = UserDefaultsVoiceFilterStorage(defaults: defaults, profileStoreURL: profileStoreURL)

    let loaded = store.loadProfiles()

    #expect(loaded == [profile])
    #expect(defaults.data(forKey: UserDefaultsVoiceFilterStorage.profilesKey) == nil)
    #expect(FileManager.default.fileExists(atPath: profileStoreURL.path))
  }

  @Test func deleteAllProfilesWipesFileStoreAndLegacyDefaults() throws {
    let suiteName = "dspeech.tests.voicefilter.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let profileStoreURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("dspeech-voice-profiles-\(UUID().uuidString)", isDirectory: false)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      if FileManager.default.fileExists(atPath: profileStoreURL.path) {
        try? FileManager.default.removeItem(at: profileStoreURL)
      }
    }
    let store = UserDefaultsVoiceFilterStorage(defaults: defaults, profileStoreURL: profileStoreURL)
    let profile = PilotVoiceProfile(
      label: "Captain",
      voicePrint: VoicePrintVector(values: [0.1, 0.2, 0.3, 0.4], quality: 0.83),
      enrolledAt: Date(timeIntervalSince1970: 748_137_600)
    )
    store.saveProfiles([profile])
    defaults.set(
      try JSONEncoder().encode([profile]),
      forKey: UserDefaultsVoiceFilterStorage.profilesKey
    )

    store.deleteAllProfiles()

    #expect(store.loadProfiles().isEmpty)
    #expect(defaults.data(forKey: UserDefaultsVoiceFilterStorage.profilesKey) == nil)
    #expect(!FileManager.default.fileExists(atPath: profileStoreURL.path))
  }

  @Test func callSignRoundTripAndClear() {
    let (store, cleanup) = makeStore()
    defer { cleanup() }
    let cs = CallSign(raw: "N123AB")!
    store.saveCallSign(cs)
    #expect(store.loadCallSign() == cs)
    store.saveCallSign(nil)
    #expect(store.loadCallSign() == nil)
  }

  @Test func corruptStoredValuesAreDistinguishableFromAbsence() {
    let suiteName = "dspeech.tests.voicefilter.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data([0x00, 0x01]), forKey: UserDefaultsVoiceFilterStorage.profilesKey)
    defaults.set(Data([0x02, 0x03]), forKey: UserDefaultsVoiceFilterStorage.callSignKey)
    defaults.set(Data([0x04, 0x05]), forKey: UserDefaultsVoiceFilterStorage.configKey)
    defaults.set("not-a-bool", forKey: UserDefaultsVoiceFilterStorage.enabledKey)

    let snapshot = UserDefaultsVoiceFilterStorage(defaults: defaults).loadSnapshot()

    #expect(snapshot.profiles.isEmpty)
    #expect(snapshot.callSign == nil)
    #expect(snapshot.gateConfig == .default)
    #expect(snapshot.enabled == false)
    #expect(
      Set(snapshot.issues)
        == [
          .profilesCorrupted,
          .callSignCorrupted,
          .gateConfigCorrupted,
          .enabledFlagCorrupted,
        ])
  }

  @Test func clearingCorruptValuesRemovesOnlyCorruptKeys() {
    let suiteName = "dspeech.tests.voicefilter.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsVoiceFilterStorage(defaults: defaults)
    let validCallSign = CallSign(raw: "N123AB")!
    store.saveCallSign(validCallSign)
    defaults.set(Data([0x00, 0x01]), forKey: UserDefaultsVoiceFilterStorage.profilesKey)
    defaults.set(Data([0x04, 0x05]), forKey: UserDefaultsVoiceFilterStorage.configKey)

    store.clearCorruptValues([.profilesCorrupted, .gateConfigCorrupted])

    #expect(defaults.data(forKey: UserDefaultsVoiceFilterStorage.profilesKey) == nil)
    #expect(defaults.data(forKey: UserDefaultsVoiceFilterStorage.configKey) == nil)
    #expect(store.loadCallSign() == validCallSign)
    #expect(store.loadSnapshot().issues.isEmpty)
  }

  // A well-formed but semantically-invalid gate config (suppress threshold at/below the SpeakerMatcher
  // match boundary) collapses the [match, suppress) fail-open band and would silently reintroduce the
  // hide-a-dispatcher bug. loadSnapshot must reject it as corrupt and recover to the safe default,
  // while preserving a validly-tightened config. (2026-06-15 adversarial-review defense-in-depth.)
  @Test func gateConfigCollapsingFailOpenBandIsTreatedCorrupt() throws {
    let suiteName = "dspeech.tests.voicefilter.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    // suppress == match -> empty fail-open band -> corrupt.
    let collapsed = ATCTranscriptGateConfig(
      continuationWindowSeconds: 8, readbackMaxWords: 16,
      pilotSuppressThreshold: SpeakerMatchConfig.default.pilotMatchThreshold)
    defaults.set(
      try JSONEncoder().encode(collapsed), forKey: UserDefaultsVoiceFilterStorage.configKey)
    let snapshot = UserDefaultsVoiceFilterStorage(defaults: defaults).loadSnapshot()
    #expect(snapshot.issues.contains(.gateConfigCorrupted))
    #expect(snapshot.gateConfig == .default)

    // control: a validly-tightened suppress threshold (still above the match boundary) is preserved.
    let tightened = ATCTranscriptGateConfig(
      continuationWindowSeconds: 8, readbackMaxWords: 16, pilotSuppressThreshold: 0.78)
    defaults.set(
      try JSONEncoder().encode(tightened), forKey: UserDefaultsVoiceFilterStorage.configKey)
    let snapshot2 = UserDefaultsVoiceFilterStorage(defaults: defaults).loadSnapshot()
    #expect(!snapshot2.issues.contains(.gateConfigCorrupted))
    #expect(snapshot2.gateConfig != .default)
    #expect(
      snapshot2.gateConfig.pilotSuppressThreshold > SpeakerMatchConfig.default.pilotMatchThreshold)
  }
}

struct VoiceFilterStorageProtectionTests {
  // why: data-at-rest protection is device-enforced and the Simulator does not honour it, so we
  // cannot read the attribute back; instead we spy the exact setAttributes call the store makes and
  // assert it REQUESTS .complete for the voiceprint file (stricter than the transcript store's
  // completeUntilFirstUserAuthentication — voiceprints stay encrypted until first unlock). Audit gap.
  private final class ProtectionSpyFileManager: FileManager, @unchecked Sendable {
    private(set) var protectionCalls: [(path: String, protection: FileProtectionType?)] = []
    override func setAttributes(
      _ attributes: [FileAttributeKey: Any], ofItemAtPath path: String
    ) throws {
      protectionCalls.append((path, attributes[.protectionKey] as? FileProtectionType))
      try super.setAttributes(attributes, ofItemAtPath: path)
    }
  }

  @Test func voiceProfileFileRequestsCompleteProtection() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("dspeech-vf-\(UUID().uuidString)", isDirectory: true)
    let profileURL = dir.appendingPathComponent("profiles.json")
    defer { try? FileManager.default.removeItem(at: dir) }
    let spy = ProtectionSpyFileManager()
    let store = UserDefaultsVoiceFilterStorage(
      defaults: UserDefaults(suiteName: "dspeech.tests.vfstorage.\(UUID().uuidString)")!,
      profileStoreURL: profileURL,
      fileManager: spy)

    store.saveProfiles([
      PilotVoiceProfile(
        label: "Captain",
        voicePrint: VoicePrintVector(values: [Float](repeating: 0.1, count: 256), quality: 0.9),
        enrolledAt: Date(timeIntervalSince1970: 0))
    ])

    #if os(iOS)
      #expect(
        !spy.protectionCalls.isEmpty, "voiceprint file must request data-at-rest protection")
      let wrong = spy.protectionCalls.filter { $0.protection != .complete }
      #expect(wrong.isEmpty, "voiceprints must use .complete protection; got \(wrong.map(\.path))")
    #endif
  }
}
