import Foundation

enum VoiceFilterStorageIssue: String, Equatable, Hashable, Sendable {
  case profilesCorrupted
  case callSignCorrupted
  case gateConfigCorrupted
  case enabledFlagCorrupted

  static func userFacingSummary(_ issues: [VoiceFilterStorageIssue]) -> String {
    let fields = Set(issues)
    if fields.contains(.profilesCorrupted) {
      return
        String(
          localized:
            "The saved voice samples are corrupted. Reset the corrupted data and record the samples again."
        )
    }
    if fields.contains(.callSignCorrupted) {
      return String(
        localized: "The saved callsign is corrupted. Reset it and set the callsign again.")
    }
    return
      String(
        localized:
          "Some local voice filter settings are corrupted. Reset the corrupted data to continue safely."
      )
  }
}

struct VoiceFilterStorageSnapshot: Equatable, Sendable {
  let profiles: [PilotVoiceProfile]
  let callSign: CallSign?
  let gateConfig: ATCTranscriptGateConfig
  let enabled: Bool
  let issues: [VoiceFilterStorageIssue]
}

protocol VoiceFilterStorage: Sendable {
  func loadSnapshot() -> VoiceFilterStorageSnapshot
  func clearCorruptValues(_ issues: Set<VoiceFilterStorageIssue>)

  func loadProfiles() -> [PilotVoiceProfile]
  func saveProfiles(_ profiles: [PilotVoiceProfile])

  func loadCallSign() -> CallSign?
  func saveCallSign(_ callSign: CallSign?)

  func loadGateConfig() -> ATCTranscriptGateConfig
  func saveGateConfig(_ config: ATCTranscriptGateConfig)

  func loadEnabled() -> Bool
  func saveEnabled(_ enabled: Bool)
}

extension VoiceFilterStorage {
  func loadSnapshot() -> VoiceFilterStorageSnapshot {
    VoiceFilterStorageSnapshot(
      profiles: loadProfiles(),
      callSign: loadCallSign(),
      gateConfig: loadGateConfig(),
      enabled: loadEnabled(),
      issues: []
    )
  }

  func clearCorruptValues(_ issues: Set<VoiceFilterStorageIssue>) {
    if issues.contains(.profilesCorrupted) { saveProfiles([]) }
    if issues.contains(.callSignCorrupted) { saveCallSign(nil) }
    if issues.contains(.gateConfigCorrupted) { saveGateConfig(.default) }
    if issues.contains(.enabledFlagCorrupted) { saveEnabled(false) }
  }
}

struct UserDefaultsVoiceFilterStorage: VoiceFilterStorage, @unchecked Sendable {
  static let profilesKey = "dspeech.voicefilter.profiles.v1"
  static let callSignKey = "dspeech.voicefilter.callsign.v1"
  static let configKey = "dspeech.voicefilter.gateconfig.v1"
  static let enabledKey = "dspeech.voicefilter.enabled.v1"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func loadProfiles() -> [PilotVoiceProfile] {
    loadSnapshot().profiles
  }

  func saveProfiles(_ profiles: [PilotVoiceProfile]) {
    guard let data = try? JSONEncoder().encode(profiles) else { return }
    defaults.set(data, forKey: Self.profilesKey)
  }

  func loadCallSign() -> CallSign? {
    loadSnapshot().callSign
  }

  func saveCallSign(_ callSign: CallSign?) {
    guard let callSign else {
      defaults.removeObject(forKey: Self.callSignKey)
      return
    }
    guard let data = try? JSONEncoder().encode(callSign) else { return }
    defaults.set(data, forKey: Self.callSignKey)
  }

  func loadGateConfig() -> ATCTranscriptGateConfig {
    loadSnapshot().gateConfig
  }

  func saveGateConfig(_ config: ATCTranscriptGateConfig) {
    guard let data = try? JSONEncoder().encode(config) else { return }
    defaults.set(data, forKey: Self.configKey)
  }

  func loadEnabled() -> Bool {
    loadSnapshot().enabled
  }

  func saveEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: Self.enabledKey)
  }

  func loadSnapshot() -> VoiceFilterStorageSnapshot {
    var issues: [VoiceFilterStorageIssue] = []
    let decoder = JSONDecoder()

    let profiles: [PilotVoiceProfile]
    if let data = defaults.data(forKey: Self.profilesKey) {
      do {
        profiles = try decoder.decode([PilotVoiceProfile].self, from: data)
      } catch {
        profiles = []
        issues.append(.profilesCorrupted)
      }
    } else {
      profiles = []
    }

    let callSign: CallSign?
    if let data = defaults.data(forKey: Self.callSignKey) {
      do {
        callSign = try decoder.decode(CallSign.self, from: data)
      } catch {
        callSign = nil
        issues.append(.callSignCorrupted)
      }
    } else {
      callSign = nil
    }

    let gateConfig: ATCTranscriptGateConfig
    if let data = defaults.data(forKey: Self.configKey) {
      do {
        gateConfig = try decoder.decode(ATCTranscriptGateConfig.self, from: data)
      } catch {
        gateConfig = .default
        issues.append(.gateConfigCorrupted)
      }
    } else {
      gateConfig = .default
    }

    let enabled: Bool
    if let stored = defaults.object(forKey: Self.enabledKey) {
      if let stored = stored as? Bool {
        enabled = stored
      } else {
        enabled = false
        issues.append(.enabledFlagCorrupted)
      }
    } else {
      enabled = false
    }

    return VoiceFilterStorageSnapshot(
      profiles: profiles,
      callSign: callSign,
      gateConfig: gateConfig,
      enabled: enabled,
      issues: issues
    )
  }

  func clearCorruptValues(_ issues: Set<VoiceFilterStorageIssue>) {
    if issues.contains(.profilesCorrupted) { defaults.removeObject(forKey: Self.profilesKey) }
    if issues.contains(.callSignCorrupted) { defaults.removeObject(forKey: Self.callSignKey) }
    if issues.contains(.gateConfigCorrupted) { defaults.removeObject(forKey: Self.configKey) }
    if issues.contains(.enabledFlagCorrupted) { defaults.removeObject(forKey: Self.enabledKey) }
  }
}
