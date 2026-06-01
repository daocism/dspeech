import Foundation

protocol VoiceFilterStorage: Sendable {
  func loadProfiles() -> [PilotVoiceProfile]
  func saveProfiles(_ profiles: [PilotVoiceProfile])

  func loadCallSign() -> CallSign?
  func saveCallSign(_ callSign: CallSign?)

  func loadGateConfig() -> ATCTranscriptGateConfig
  func saveGateConfig(_ config: ATCTranscriptGateConfig)

  func loadEnabled() -> Bool
  func saveEnabled(_ enabled: Bool)
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
    guard let data = defaults.data(forKey: Self.profilesKey) else { return [] }
    return (try? JSONDecoder().decode([PilotVoiceProfile].self, from: data)) ?? []
  }

  func saveProfiles(_ profiles: [PilotVoiceProfile]) {
    guard let data = try? JSONEncoder().encode(profiles) else { return }
    defaults.set(data, forKey: Self.profilesKey)
  }

  func loadCallSign() -> CallSign? {
    guard let data = defaults.data(forKey: Self.callSignKey) else { return nil }
    return try? JSONDecoder().decode(CallSign.self, from: data)
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
    guard let data = defaults.data(forKey: Self.configKey),
      let decoded = try? JSONDecoder().decode(ATCTranscriptGateConfig.self, from: data)
    else {
      return .default
    }
    return decoded
  }

  func saveGateConfig(_ config: ATCTranscriptGateConfig) {
    guard let data = try? JSONEncoder().encode(config) else { return }
    defaults.set(data, forKey: Self.configKey)
  }

  func loadEnabled() -> Bool {
    defaults.object(forKey: Self.enabledKey) as? Bool ?? false
  }

  func saveEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: Self.enabledKey)
  }
}
