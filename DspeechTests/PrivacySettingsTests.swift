import Foundation
import Testing

@testable import Dspeech

@MainActor
struct PrivacySettingsTests {
  enum TestError: Error {
    case saveFailed
  }

  final class InMemoryStorage: PrivacySettingsStorage, @unchecked Sendable {
    var stored: PrivacyMode?
    var storedVoiceFilterActive: Bool?
    var failSaves = false
    func loadPrivacyMode() -> PrivacyMode { stored ?? .localOnly }
    func savePrivacyMode(_ mode: PrivacyMode) throws {
      if failSaves { throw TestError.saveFailed }
      stored = mode
    }
    func loadVoiceFilterActive() -> Bool { storedVoiceFilterActive ?? true }
    func saveVoiceFilterActive(_ active: Bool) throws {
      if failSaves { throw TestError.saveFailed }
      storedVoiceFilterActive = active
    }
  }

  @Test func defaultModeIsLocalOnly() {
    let storage = InMemoryStorage()
    let settings = PrivacySettings(storage: storage)
    #expect(settings.mode == .localOnly)
    #expect(settings.voiceFilterActive == true)
    #expect(settings.storageIssue == nil)
  }

  @Test func privacyModeSurfaceIsLocalOnly() {
    #expect(PrivacyMode.allCases == [.localOnly])
  }

  @Test func modeReflectsStoredLocalValueOnInit() {
    let storage = InMemoryStorage()
    storage.stored = .localOnly
    let settings = PrivacySettings(storage: storage)
    #expect(settings.mode == .localOnly)
  }

  @Test func localOnlyDoesNotSendAudioOffDevice() {
    #expect(PrivacyMode.localOnly.sendsAudioOffDevice == false)
  }

  @Test func badgeTextMatchesMode() {
    #expect(PrivacyMode.localOnly.badgeText == "LOCAL")
  }

  @Test func voiceFilterActiveDefaultsTrueAndPersistsOff() {
    let storage = InMemoryStorage()
    let settings = PrivacySettings(storage: storage)
    #expect(settings.voiceFilterActive)

    settings.voiceFilterActive = false

    #expect(settings.voiceFilterActive == false)
    #expect(storage.storedVoiceFilterActive == false)
    #expect(settings.storageIssue == nil)
  }

  @Test func voiceFilterSaveFailureSurfacesStaleSettingsIssue() {
    let storage = InMemoryStorage()
    storage.failSaves = true
    let settings = PrivacySettings(storage: storage)

    settings.voiceFilterActive = false

    #expect(settings.voiceFilterActive == false)
    #expect(storage.storedVoiceFilterActive == nil)
    #expect(settings.storageIssue == .voiceFilterActiveSaveFailed)
    #expect(settings.hasStaleSettings)
  }

  @Test func userDefaultsRoundTrip() throws {
    let suiteName = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let storage = UserDefaultsPrivacySettingsStorage(defaults: defaults)
    #expect(storage.loadPrivacyMode() == .localOnly)

    try storage.savePrivacyMode(.localOnly)
    #expect(storage.loadPrivacyMode() == .localOnly)

    #expect(storage.loadVoiceFilterActive() == true)
    try storage.saveVoiceFilterActive(false)
    #expect(storage.loadVoiceFilterActive() == false)
    try storage.saveVoiceFilterActive(true)
    #expect(storage.loadVoiceFilterActive() == true)
  }

  @Test func userDefaultsUnknownPrivacyModeResolvesToLocalOnly() {
    let suiteName = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storage = UserDefaultsPrivacySettingsStorage(defaults: defaults)

    defaults.set("legacyRemoteOptIn", forKey: UserDefaultsPrivacySettingsStorage.privacyModeKey)

    #expect(storage.loadPrivacyMode() == .localOnly)
    #expect(storage.loadIssue() == .privacyModeCorrupted)
  }

  @Test func userDefaultsParsesVoiceFilterLaunchArguments() {
    let suiteName = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storage = UserDefaultsPrivacySettingsStorage(defaults: defaults)

    defaults.set("false", forKey: UserDefaultsPrivacySettingsStorage.voiceFilterActiveKey)
    #expect(storage.loadVoiceFilterActive() == false)

    defaults.set("true", forKey: UserDefaultsPrivacySettingsStorage.voiceFilterActiveKey)
    #expect(storage.loadVoiceFilterActive() == true)
    #expect(storage.loadIssue() == nil)
  }

  @Test func userDefaultsUnknownVoiceFilterFlagFallsBackOffAndSurfacesIssue() {
    let suiteName = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storage = UserDefaultsPrivacySettingsStorage(defaults: defaults)

    defaults.set("maybe", forKey: UserDefaultsPrivacySettingsStorage.voiceFilterActiveKey)

    #expect(storage.loadVoiceFilterActive() == false)
    #expect(storage.loadIssue() == .voiceFilterActiveCorrupted)
    let settings = PrivacySettings(storage: storage)
    #expect(settings.voiceFilterActive == false)
    #expect(settings.storageIssue == .voiceFilterActiveCorrupted)
  }
}
