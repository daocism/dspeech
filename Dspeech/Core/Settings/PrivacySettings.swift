import Foundation
import Observation

enum PrivacyMode: String, CaseIterable, Sendable, Codable {
    case localOnly

    var displayName: String {
        "Локально"
    }

    var badgeText: String {
        "LOCAL"
    }

    var sendsAudioOffDevice: Bool {
        false
    }
}

protocol PrivacySettingsStorage: Sendable {
    func loadPrivacyMode() -> PrivacyMode
    func savePrivacyMode(_ mode: PrivacyMode)

    func loadVoiceFilterActive() -> Bool
    func saveVoiceFilterActive(_ active: Bool)
}

struct UserDefaultsPrivacySettingsStorage: PrivacySettingsStorage, @unchecked Sendable {
    static let privacyModeKey = "dspeech.privacy.mode.v1"
    static let voiceFilterActiveKey = "dspeech.privacy.voicefilter.active.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadPrivacyMode() -> PrivacyMode {
        guard let raw = defaults.string(forKey: Self.privacyModeKey),
              let mode = PrivacyMode(rawValue: raw) else {
            return .localOnly
        }
        return mode
    }

    func savePrivacyMode(_ mode: PrivacyMode) {
        defaults.set(mode.rawValue, forKey: Self.privacyModeKey)
    }

    func loadVoiceFilterActive() -> Bool {
        if let active = defaults.object(forKey: Self.voiceFilterActiveKey) as? Bool {
            return active
        }
        if let raw = defaults.string(forKey: Self.voiceFilterActiveKey) {
            switch raw.lowercased() {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                return true
            }
        }
        return true
    }

    func saveVoiceFilterActive(_ active: Bool) {
        defaults.set(active, forKey: Self.voiceFilterActiveKey)
    }
}

@MainActor
@Observable
final class PrivacySettings {
    private let storage: PrivacySettingsStorage

    var mode: PrivacyMode {
        didSet {
            guard mode != oldValue else { return }
            storage.savePrivacyMode(mode)
        }
    }

    var voiceFilterActive: Bool {
        didSet {
            guard voiceFilterActive != oldValue else { return }
            storage.saveVoiceFilterActive(voiceFilterActive)
        }
    }

    init(storage: PrivacySettingsStorage = UserDefaultsPrivacySettingsStorage()) {
        self.storage = storage
        self.mode = storage.loadPrivacyMode()
        self.voiceFilterActive = storage.loadVoiceFilterActive()
    }
}
