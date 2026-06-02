import Foundation
import Observation

protocol AudioSettingsStorage: Sendable {
  func loadPreferredInputUID() -> String?
  func savePreferredInputUID(_ uid: String?)
  func loadPreferredInputType() -> String?
  func savePreferredInputType(_ type: String?)
}

struct UserDefaultsAudioSettingsStorage: AudioSettingsStorage, @unchecked Sendable {
  static let uidKey = "dspeech.audio.preferredinput.uid.v1"
  static let typeKey = "dspeech.audio.preferredinput.type.v1"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func loadPreferredInputUID() -> String? { defaults.string(forKey: Self.uidKey) }
  func savePreferredInputUID(_ uid: String?) {
    if let uid {
      defaults.set(uid, forKey: Self.uidKey)
    } else {
      defaults.removeObject(forKey: Self.uidKey)
    }
  }
  func loadPreferredInputType() -> String? { defaults.string(forKey: Self.typeKey) }
  func savePreferredInputType(_ type: String?) {
    if let type {
      defaults.set(type, forKey: Self.typeKey)
    } else {
      defaults.removeObject(forKey: Self.typeKey)
    }
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

  init(storage: AudioSettingsStorage = UserDefaultsAudioSettingsStorage()) {
    self.storage = storage
    self.preferredInputUID = storage.loadPreferredInputUID()
    self.preferredInputType = storage.loadPreferredInputType()
  }

  func setPreferred(uid: String, type: String) {
    preferredInputUID = uid
    preferredInputType = type
    storage.savePreferredInputUID(uid)
    storage.savePreferredInputType(type)
  }
}
