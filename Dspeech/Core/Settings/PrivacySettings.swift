import Foundation
import Observation

/// Parses a defaults value that was written as a string (legacy / MDM-pushed config) into a Bool,
/// returning nil for anything that isn't a recognized boolean literal. Shared by the settings
/// storages that must tolerate a string-typed value where a Bool is expected (and flag the rest as
/// corrupted).
enum SettingsBoolParsing {
  static func parse(_ raw: String) -> Bool? {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes":
      return true
    case "0", "false", "no":
      return false
    default:
      return nil
    }
  }
}

enum PrivacyMode: String, CaseIterable, Sendable, Codable {
  case localOnly

  var displayName: String {
    String(localized: "Local")
  }

  var badgeText: String {
    String(localized: "LOCAL")
  }

  var sendsAudioOffDevice: Bool {
    false
  }
}

enum SettingsStorageIssue: Equatable, Sendable {
  case privacyModeCorrupted
  case voiceFilterActiveCorrupted
  case privacyModeSaveFailed
  case voiceFilterActiveSaveFailed
  case recognitionLocaleCorrupted
  case recognitionLocaleSaveFailed
  case recognitionEngineCorrupted
  case recognitionEngineSaveFailed
  case transmissionGapSaveFailed
  case translationEnabledCorrupted
  case translationTargetCorrupted
  case translationEnabledSaveFailed
  case translationTargetSaveFailed
  case audioPreferredInputCorrupted
  case audioPreferredInputSaveFailed
}

protocol PrivacySettingsStorage: Sendable {
  func loadPrivacyMode() -> PrivacyMode
  func savePrivacyMode(_ mode: PrivacyMode) throws

  func loadVoiceFilterActive() -> Bool
  func saveVoiceFilterActive(_ active: Bool) throws
  func loadIssue() -> SettingsStorageIssue?
}

extension PrivacySettingsStorage {
  func loadIssue() -> SettingsStorageIssue? { nil }
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
      let mode = PrivacyMode(rawValue: raw)
    else {
      return .localOnly
    }
    return mode
  }

  func savePrivacyMode(_ mode: PrivacyMode) throws {
    defaults.set(mode.rawValue, forKey: Self.privacyModeKey)
  }

  func loadVoiceFilterActive() -> Bool {
    if let active = defaults.object(forKey: Self.voiceFilterActiveKey) as? Bool {
      return active
    }
    if let raw = defaults.string(forKey: Self.voiceFilterActiveKey) {
      return SettingsBoolParsing.parse(raw) ?? false
    }
    if defaults.object(forKey: Self.voiceFilterActiveKey) != nil { return false }
    return true
  }

  func saveVoiceFilterActive(_ active: Bool) throws {
    defaults.set(active, forKey: Self.voiceFilterActiveKey)
  }

  func loadIssue() -> SettingsStorageIssue? {
    if let raw = defaults.string(forKey: Self.privacyModeKey),
      PrivacyMode(rawValue: raw) == nil
    {
      return .privacyModeCorrupted
    }
    let rawVoiceFilter = defaults.object(forKey: Self.voiceFilterActiveKey)
    if rawVoiceFilter == nil || rawVoiceFilter is Bool { return nil }
    if let raw = rawVoiceFilter as? String, SettingsBoolParsing.parse(raw) != nil { return nil }
    return .voiceFilterActiveCorrupted
  }
}

@MainActor
@Observable
final class PrivacySettings {
  private let storage: PrivacySettingsStorage
  private(set) var storageIssue: SettingsStorageIssue?
  var hasStaleSettings: Bool { storageIssue != nil }

  var mode: PrivacyMode {
    didSet {
      guard mode != oldValue else { return }
      do {
        try storage.savePrivacyMode(mode)
        storageIssue = nil
      } catch {
        storageIssue = .privacyModeSaveFailed
      }
    }
  }

  var voiceFilterActive: Bool {
    didSet {
      guard voiceFilterActive != oldValue else { return }
      do {
        try storage.saveVoiceFilterActive(voiceFilterActive)
        storageIssue = nil
      } catch {
        storageIssue = .voiceFilterActiveSaveFailed
      }
    }
  }

  init(storage: PrivacySettingsStorage = UserDefaultsPrivacySettingsStorage()) {
    self.storage = storage
    self.mode = storage.loadPrivacyMode()
    self.voiceFilterActive = storage.loadVoiceFilterActive()
    self.storageIssue = storage.loadIssue()
  }
}
