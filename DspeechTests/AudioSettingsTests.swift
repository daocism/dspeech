import Foundation
import Testing

@testable import Dspeech

@MainActor
struct AudioSettingsTests {
  enum TestError: Error {
    case saveFailed
  }

  final class InMemoryStorage: AudioSettingsStorage, @unchecked Sendable {
    var uid: String?
    var type: String?
    var failSaves = false
    func loadPreferredInputUID() -> String? { uid }
    func savePreferredInputUID(_ value: String?) throws {
      if failSaves { throw TestError.saveFailed }
      uid = value
    }
    func loadPreferredInputType() -> String? { type }
    func savePreferredInputType(_ value: String?) throws {
      if failSaves { throw TestError.saveFailed }
      type = value
    }
  }

  private func port(_ type: AudioPortType, _ name: String, _ uid: String) -> PortSnapshot {
    PortSnapshot(portType: type, portName: name, uid: uid)
  }

  @Test func defaultsToNoPreference() {
    let settings = AudioSettings(storage: InMemoryStorage())
    #expect(settings.preferredInputUID == nil)
    #expect(settings.preferredInputType == nil)
    #expect(settings.storageIssue == nil)
  }

  @Test func setPreferredPersists() {
    let storage = InMemoryStorage()
    let settings = AudioSettings(storage: storage)
    settings.setPreferred(uid: "uid-1", type: "USBAudio")
    #expect(settings.preferredInputUID == "uid-1")
    #expect(storage.uid == "uid-1")
    #expect(storage.type == "USBAudio")
    #expect(settings.storageIssue == nil)
  }

  @Test func setPreferredSaveFailureSurfacesStaleSettingsIssue() {
    let storage = InMemoryStorage()
    storage.failSaves = true
    let settings = AudioSettings(storage: storage)

    settings.setPreferred(uid: "uid-1", type: "USBAudio")

    #expect(settings.preferredInputUID == "uid-1")
    #expect(settings.preferredInputType == "USBAudio")
    #expect(storage.uid == nil)
    #expect(storage.type == nil)
    #expect(settings.storageIssue == .audioPreferredInputSaveFailed)
    #expect(settings.hasStaleSettings)
  }

  @Test func reflectsStoredOnInit() {
    let storage = InMemoryStorage()
    storage.uid = "uid-x"
    storage.type = "MicrophoneBuiltIn"
    let settings = AudioSettings(storage: storage)
    #expect(settings.preferredInputUID == "uid-x")
    #expect(settings.preferredInputType == "MicrophoneBuiltIn")
  }

  @Test func resolverPrefersExactUID() {
    let usb = port(.usbAudio, "USB", "u-usb")
    let mic = port(.builtInMic, "Mic", "u-mic")
    let resolved = PreferredInputResolver.resolve(
      uid: "u-usb", type: "MicrophoneBuiltIn", available: [mic, usb])
    #expect(resolved?.uid == "u-usb")
  }

  @Test func resolverFallsBackToType() {
    let mic = port(.builtInMic, "Mic", "u-mic")
    let resolved = PreferredInputResolver.resolve(
      uid: "gone", type: "MicrophoneBuiltIn", available: [mic])
    #expect(resolved?.uid == "u-mic")
  }

  @Test func resolverReturnsNilWhenNoMatch() {
    let mic = port(.builtInMic, "Mic", "u-mic")
    let resolved = PreferredInputResolver.resolve(uid: "x", type: "USBAudio", available: [mic])
    #expect(resolved == nil)
  }

  @Test func userDefaultsRoundTrip() throws {
    let suite = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let storage = UserDefaultsAudioSettingsStorage(defaults: defaults)

    #expect(storage.loadPreferredInputUID() == nil)
    try storage.savePreferredInputUID("u1")
    try storage.savePreferredInputType("USBAudio")
    #expect(storage.loadPreferredInputUID() == "u1")
    #expect(storage.loadPreferredInputType() == "USBAudio")

    try storage.savePreferredInputUID(nil)
    #expect(storage.loadPreferredInputUID() == nil)
  }

  @Test func userDefaultsBlankPersistedInputFallsBackToNilAndSurfacesIssue() {
    let suite = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let storage = UserDefaultsAudioSettingsStorage(defaults: defaults)

    defaults.set("", forKey: UserDefaultsAudioSettingsStorage.uidKey)

    #expect(storage.loadPreferredInputUID() == nil)
    #expect(storage.loadIssue() == .audioPreferredInputCorrupted)
  }
}

// MARK: - M1 download settings (Wi-Fi-only default) + cellular error mapping

@MainActor
struct DownloadSettingsTests {
  enum TestError: Error { case saveFailed }

  final class InMemoryStorage: DownloadSettingsStorage, @unchecked Sendable {
    var allow: Bool
    var failSaves = false
    var issue: SettingsStorageIssue?
    init(allow: Bool = false) { self.allow = allow }
    func loadAllowCellular() -> Bool { allow }
    func saveAllowCellular(_ value: Bool) throws {
      if failSaves { throw TestError.saveFailed }
      allow = value
    }
    func loadIssue() -> SettingsStorageIssue? { issue }
  }

  @Test func defaultsToWiFiOnly() {
    let settings = DownloadSettings(storage: InMemoryStorage())
    #expect(settings.allowCellular == false)
    #expect(settings.storageIssue == nil)
  }

  @Test func togglingCellularPersists() {
    let storage = InMemoryStorage()
    let settings = DownloadSettings(storage: storage)
    settings.allowCellular = true
    #expect(storage.allow == true)
    #expect(settings.storageIssue == nil)
  }

  @Test func saveFailureSurfacesStaleSettingsIssue() {
    let storage = InMemoryStorage()
    storage.failSaves = true
    let settings = DownloadSettings(storage: storage)

    settings.allowCellular = true

    #expect(settings.allowCellular == true)
    #expect(storage.allow == false)
    #expect(settings.storageIssue == .downloadAllowCellularSaveFailed)
    #expect(settings.hasStaleSettings)
  }

  @Test func reflectsStoredOnInit() {
    let settings = DownloadSettings(storage: InMemoryStorage(allow: true))
    #expect(settings.allowCellular == true)
  }

  @Test func userDefaultsRoundTripDefaultsFalse() throws {
    let suite = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let storage = UserDefaultsDownloadSettingsStorage(defaults: defaults)

    #expect(storage.loadAllowCellular() == false)
    try storage.saveAllowCellular(true)
    #expect(storage.loadAllowCellular() == true)
    #expect(storage.loadIssue() == nil)
    try storage.saveAllowCellular(false)
    #expect(storage.loadAllowCellular() == false)
  }

  @Test func userDefaultsToleratesStringBooleanWithoutCorruption() {
    let suite = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let storage = UserDefaultsDownloadSettingsStorage(defaults: defaults)

    // an MDM-pushed / launch-argument string boolean parses cleanly, not as corruption.
    defaults.set("true", forKey: UserDefaultsDownloadSettingsStorage.allowCellularKey)
    #expect(storage.loadAllowCellular() == true)
    #expect(storage.loadIssue() == nil)
  }

  @Test func userDefaultsNonBooleanSurfacesCorruption() {
    let suite = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let storage = UserDefaultsDownloadSettingsStorage(defaults: defaults)

    defaults.set("not-a-bool", forKey: UserDefaultsDownloadSettingsStorage.allowCellularKey)
    #expect(storage.loadAllowCellular() == false)
    #expect(storage.loadIssue() == .downloadAllowCellularCorrupted)
  }

  // why: M1 verdict — when cellular downloads are disallowed and only a cellular path is available,
  // URLSession fails the request with URLError.dataNotAllowed (NSURLErrorDataNotAllowed, -1020). That
  // code is already in the shared offline taxonomy, so a Wi-Fi-only block maps to the honest `.offline`
  // failure copy ("reconnect"), NOT the generic `.network` failure. Pinned with a hand-built error.
  @Test func cellularDisallowedErrorMapsToOfflineTaxonomy() {
    let failure = whisperKitModelDownloadFailure(for: URLError(.dataNotAllowed))
    #expect(failure.kind == .offline)
    #expect(failure.isRetryable)

    let generic = whisperKitModelDownloadFailure(for: URLError(.badServerResponse))
    #expect(generic.kind == .network)
    #expect(failure.userSafeReason != generic.userSafeReason)
  }
}
