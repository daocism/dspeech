import Foundation
import Observation

enum PrivacyMode: String, CaseIterable, Sendable, Codable {
    case localOnly
    case allowCloudFallback

    var displayName: String {
        switch self {
        case .localOnly: return "Локально"
        case .allowCloudFallback: return "Облако (согласие)"
        }
    }

    var badgeText: String {
        switch self {
        case .localOnly: return "LOCAL"
        case .allowCloudFallback: return "CLOUD"
        }
    }

    var sendsAudioOffDevice: Bool {
        self == .allowCloudFallback
    }
}

protocol PrivacySettingsStorage: Sendable {
    func loadPrivacyMode() -> PrivacyMode
    func savePrivacyMode(_ mode: PrivacyMode)
}

struct UserDefaultsPrivacySettingsStorage: PrivacySettingsStorage {
    static let privacyModeKey = "dspeech.privacy.mode.v1"

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

    init(storage: PrivacySettingsStorage = UserDefaultsPrivacySettingsStorage()) {
        self.storage = storage
        self.mode = storage.loadPrivacyMode()
    }

    var allowCloud: Bool {
        get { mode == .allowCloudFallback }
        set { mode = newValue ? .allowCloudFallback : .localOnly }
    }
}
