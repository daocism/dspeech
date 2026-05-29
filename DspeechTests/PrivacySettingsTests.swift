import Foundation
import Testing

@testable import Dspeech

@MainActor
struct PrivacySettingsTests {
  final class InMemoryStorage: PrivacySettingsStorage, @unchecked Sendable {
    var stored: PrivacyMode?
    var storedVoiceFilterActive: Bool?
    func loadPrivacyMode() -> PrivacyMode { stored ?? .localOnly }
    func savePrivacyMode(_ mode: PrivacyMode) { stored = mode }
    func loadVoiceFilterActive() -> Bool { storedVoiceFilterActive ?? true }
    func saveVoiceFilterActive(_ active: Bool) { storedVoiceFilterActive = active }
  }

  @Test func defaultModeIsLocalOnly() {
    let storage = InMemoryStorage()
    let settings = PrivacySettings(storage: storage)
    #expect(settings.mode == .localOnly)
    #expect(settings.voiceFilterActive == true)
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
  }

  @Test func userDefaultsRoundTrip() {
    let suiteName = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let storage = UserDefaultsPrivacySettingsStorage(defaults: defaults)
    #expect(storage.loadPrivacyMode() == .localOnly)

    storage.savePrivacyMode(.localOnly)
    #expect(storage.loadPrivacyMode() == .localOnly)

    #expect(storage.loadVoiceFilterActive() == true)
    storage.saveVoiceFilterActive(false)
    #expect(storage.loadVoiceFilterActive() == false)
    storage.saveVoiceFilterActive(true)
    #expect(storage.loadVoiceFilterActive() == true)
  }

  @Test func userDefaultsUnknownPrivacyModeResolvesToLocalOnly() {
    let suiteName = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storage = UserDefaultsPrivacySettingsStorage(defaults: defaults)

    defaults.set("legacyRemoteOptIn", forKey: UserDefaultsPrivacySettingsStorage.privacyModeKey)

    #expect(storage.loadPrivacyMode() == .localOnly)
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
  }
}
