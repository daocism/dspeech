import Foundation
import Observation

protocol AudioSettingsStorage: Sendable {
  func loadPreferredInputUID() -> String?
  func savePreferredInputUID(_ uid: String?) throws
  func loadPreferredInputType() -> String?
  func savePreferredInputType(_ type: String?) throws
  func loadIssue() -> SettingsStorageIssue?
}

extension AudioSettingsStorage {
  func loadIssue() -> SettingsStorageIssue? { nil }
}

struct UserDefaultsAudioSettingsStorage: AudioSettingsStorage, @unchecked Sendable {
  static let uidKey = "dspeech.audio.preferredinput.uid.v1"
  static let typeKey = "dspeech.audio.preferredinput.type.v1"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func loadPreferredInputUID() -> String? {
    guard let uid = defaults.string(forKey: Self.uidKey), !uid.isEmpty else {
      return nil
    }
    return uid
  }

  func savePreferredInputUID(_ uid: String?) throws {
    if let uid {
      defaults.set(uid, forKey: Self.uidKey)
    } else {
      defaults.removeObject(forKey: Self.uidKey)
    }
  }

  func loadPreferredInputType() -> String? {
    guard let type = defaults.string(forKey: Self.typeKey), !type.isEmpty else {
      return nil
    }
    return type
  }

  func savePreferredInputType(_ type: String?) throws {
    if let type {
      defaults.set(type, forKey: Self.typeKey)
    } else {
      defaults.removeObject(forKey: Self.typeKey)
    }
  }

  func loadIssue() -> SettingsStorageIssue? {
    if let uid = defaults.string(forKey: Self.uidKey), uid.isEmpty {
      return .audioPreferredInputCorrupted
    }
    if let type = defaults.string(forKey: Self.typeKey), type.isEmpty {
      return .audioPreferredInputCorrupted
    }
    return nil
  }
}

// MARK: - Download settings (M1: model downloads default to Wi-Fi only)

// why: M1 — model/pack downloads (hundreds of MB) must not silently burn a pilot's cellular data.
// A dedicated persisted setting (default OFF = Wi-Fi only) governs BOTH pinned downloaders
// (WhisperKit + speaker model pack), following the PrivacySettings storage-protocol template so the
// @Observable model stays a pure value holder and persistence is injectable for round-trip +
// corruption tests. Lives here (not a new file) per the pbxproj no-new-file constraint.
protocol DownloadSettingsStorage: Sendable {
  func loadAllowCellular() -> Bool
  func saveAllowCellular(_ allow: Bool) throws
  func loadIssue() -> SettingsStorageIssue?
}

extension DownloadSettingsStorage {
  func loadIssue() -> SettingsStorageIssue? { nil }
}

struct UserDefaultsDownloadSettingsStorage: DownloadSettingsStorage, @unchecked Sendable {
  static let allowCellularKey = "dspeech.downloads.allow-cellular.v1"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func loadAllowCellular() -> Bool {
    if let value = defaults.object(forKey: Self.allowCellularKey) as? Bool {
      return value
    }
    if let raw = defaults.string(forKey: Self.allowCellularKey) {
      return SettingsBoolParsing.parse(raw) ?? false
    }
    // why: default OFF — a fresh install waits for Wi-Fi before any multi-hundred-MB model download.
    return false
  }

  func saveAllowCellular(_ allow: Bool) throws {
    defaults.set(allow, forKey: Self.allowCellularKey)
  }

  func loadIssue() -> SettingsStorageIssue? {
    let raw = defaults.object(forKey: Self.allowCellularKey)
    if raw == nil || raw is Bool { return nil }
    if let string = raw as? String, SettingsBoolParsing.parse(string) != nil { return nil }
    return .downloadAllowCellularCorrupted
  }
}

@MainActor
@Observable
final class DownloadSettings {
  private let storage: DownloadSettingsStorage
  private(set) var storageIssue: SettingsStorageIssue?
  var hasStaleSettings: Bool { storageIssue != nil }

  var allowCellular: Bool {
    didSet {
      guard allowCellular != oldValue else { return }
      do {
        try storage.saveAllowCellular(allowCellular)
        storageIssue = nil
      } catch {
        storageIssue = .downloadAllowCellularSaveFailed
      }
    }
  }

  init(storage: DownloadSettingsStorage = UserDefaultsDownloadSettingsStorage()) {
    self.storage = storage
    self.allowCellular = storage.loadAllowCellular()
    self.storageIssue = storage.loadIssue()
  }
}

enum PreferredInputResolver {
  // why: prefer an exact uid match (same physical device), else fall back to the
  // saved port type (a reconnected device of the same kind), else nil.
  static func resolve(
    uid: String?,
    type: String?,
    available: [PortSnapshot]
  ) -> PortSnapshot? {
    if let uid, !uid.isEmpty, let match = available.first(where: { $0.uid == uid }) {
      return match
    }
    if let type, let match = available.first(where: { $0.portType.rawValue == type }) {
      return match
    }
    return nil
  }
}

@MainActor
@Observable
final class AudioSettings {
  private let storage: AudioSettingsStorage
  private(set) var preferredInputUID: String?
  private(set) var preferredInputType: String?
  private(set) var storageIssue: SettingsStorageIssue?
  var hasStaleSettings: Bool { storageIssue != nil }

  init(storage: AudioSettingsStorage = UserDefaultsAudioSettingsStorage()) {
    self.storage = storage
    self.preferredInputUID = storage.loadPreferredInputUID()
    self.preferredInputType = storage.loadPreferredInputType()
    self.storageIssue = storage.loadIssue()
  }

  func setPreferred(uid: String, type: String) {
    preferredInputUID = uid
    preferredInputType = type
    do {
      try storage.savePreferredInputUID(uid)
      try storage.savePreferredInputType(type)
      storageIssue = nil
    } catch {
      storageIssue = .audioPreferredInputSaveFailed
    }
  }
}
