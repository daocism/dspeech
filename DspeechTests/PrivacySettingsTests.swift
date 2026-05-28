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
        #expect(settings.allowCloud == false)
        #expect(settings.voiceFilterActive == true)
    }

    @Test func togglingAllowCloudSwitchesToCloudFallback() {
        let storage = InMemoryStorage()
        let settings = PrivacySettings(storage: storage)

        settings.allowCloud = true

        #expect(settings.mode == .allowCloudFallback)
        #expect(storage.stored == .allowCloudFallback)
    }

    @Test func togglingAllowCloudOffReturnsToLocalOnly() {
        let storage = InMemoryStorage()
        storage.stored = .allowCloudFallback
        let settings = PrivacySettings(storage: storage)

        settings.allowCloud = false

        #expect(settings.mode == .localOnly)
        #expect(storage.stored == .localOnly)
    }

    @Test func modeReflectsStoredValueOnInit() {
        let storage = InMemoryStorage()
        storage.stored = .allowCloudFallback
        let settings = PrivacySettings(storage: storage)
        #expect(settings.mode == .allowCloudFallback)
        #expect(settings.allowCloud)
    }

    @Test func localOnlyDoesNotSendAudioOffDevice() {
        #expect(PrivacyMode.localOnly.sendsAudioOffDevice == false)
        #expect(PrivacyMode.allowCloudFallback.sendsAudioOffDevice == true)
    }

    @Test func badgeTextMatchesMode() {
        #expect(PrivacyMode.localOnly.badgeText == "LOCAL")
        #expect(PrivacyMode.allowCloudFallback.badgeText == "CLOUD")
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

        storage.savePrivacyMode(.allowCloudFallback)
        #expect(storage.loadPrivacyMode() == .allowCloudFallback)

        storage.savePrivacyMode(.localOnly)
        #expect(storage.loadPrivacyMode() == .localOnly)

        #expect(storage.loadVoiceFilterActive() == true)
        storage.saveVoiceFilterActive(false)
        #expect(storage.loadVoiceFilterActive() == false)
        storage.saveVoiceFilterActive(true)
        #expect(storage.loadVoiceFilterActive() == true)
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
