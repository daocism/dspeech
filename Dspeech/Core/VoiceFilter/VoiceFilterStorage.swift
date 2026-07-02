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
  func deleteAllProfiles()

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

  func deleteAllProfiles() {
    saveProfiles([])
  }
}

struct UserDefaultsVoiceFilterStorage: VoiceFilterStorage, @unchecked Sendable {
  static let profilesKey = "dspeech.voicefilter.profiles.v1"
  static let callSignKey = "dspeech.voicefilter.callsign.v1"
  static let configKey = "dspeech.voicefilter.gateconfig.v1"
  static let enabledKey = "dspeech.voicefilter.enabled.v1"
  static let profileStoreFileName = "pilot-voice-profiles.v1.json"

  let defaults: UserDefaults
  let profileStoreURL: URL
  // why: injectable so a test can spy the data-at-rest protection request (the Simulator does not
  // enforce FileProtection, so the only way to assert it is to observe the setAttributes call).
  let fileManager: FileManager

  init(
    defaults: UserDefaults = .standard,
    profileStoreURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.defaults = defaults
    self.profileStoreURL = profileStoreURL ?? Self.defaultProfileStoreURL()
    self.fileManager = fileManager
  }

  func loadProfiles() -> [PilotVoiceProfile] {
    loadSnapshot().profiles
  }

  func saveProfiles(_ profiles: [PilotVoiceProfile]) {
    do {
      try persistProfiles(profiles)
      defaults.removeObject(forKey: Self.profilesKey)
    } catch {
      // why: surface to the log/crash-report boundary (`log collect`) instead of swallowing — a
      // silent persist failure would let the UI claim success while the voiceprint never saved.
      // Error is .private (may carry a path); no voiceprint content is logged.
      DspeechLog.voiceFilter.error(
        "voiceprint persist failed error=\(String(describing: error), privacy: .private)"
      )
    }
  }

  func deleteAllProfiles() {
    if fileManager.fileExists(atPath: profileStoreURL.path) {
      do {
        try fileManager.removeItem(at: profileStoreURL)
      } catch {
        // why: a silent delete failure leaves personal voiceprints on disk after the user removed
        // the feature (a privacy/data-retention leak) — surface it rather than swallow.
        DspeechLog.voiceFilter.error(
          "voiceprint delete failed error=\(String(describing: error), privacy: .private)"
        )
      }
    }
    defaults.removeObject(forKey: Self.profilesKey)
  }

  func loadCallSign() -> CallSign? {
    loadSnapshot().callSign
  }

  func saveCallSign(_ callSign: CallSign?) {
    guard let callSign else {
      defaults.removeObject(forKey: Self.callSignKey)
      return
    }
    do {
      let data = try JSONEncoder().encode(callSign)
      defaults.set(data, forKey: Self.callSignKey)
    } catch {
      DspeechLog.voiceFilter.error(
        "callsign persist failed error=\(String(describing: error), privacy: .private)")
    }
  }

  func loadGateConfig() -> ATCTranscriptGateConfig {
    loadSnapshot().gateConfig
  }

  func saveGateConfig(_ config: ATCTranscriptGateConfig) {
    do {
      let data = try JSONEncoder().encode(config)
      defaults.set(data, forKey: Self.configKey)
    } catch {
      DspeechLog.voiceFilter.error(
        "gate config persist failed error=\(String(describing: error), privacy: .private)")
    }
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

    let profileLoad = loadProfilesFromFileOrMigratedDefaults(decoder: decoder)
    let profiles = profileLoad.profiles
    issues.append(contentsOf: profileLoad.issues)

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
        let decoded = try decoder.decode(ATCTranscriptGateConfig.self, from: data)
        // why: a well-formed but semantically-invalid suppress threshold (at or below the SpeakerMatcher
        // match boundary) collapses the [match, suppress) fail-open band and silently reintroduces the
        // hide-a-dispatcher bug. Treat it as corrupt and recover to the safe default, same as a decode
        // failure.
        if decoded.pilotSuppressThreshold > SpeakerMatchConfig.default.pilotMatchThreshold {
          gateConfig = decoded
        } else {
          gateConfig = .default
          issues.append(.gateConfigCorrupted)
        }
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
    if issues.contains(.profilesCorrupted) { deleteAllProfiles() }
    if issues.contains(.callSignCorrupted) { defaults.removeObject(forKey: Self.callSignKey) }
    if issues.contains(.gateConfigCorrupted) { defaults.removeObject(forKey: Self.configKey) }
    if issues.contains(.enabledFlagCorrupted) { defaults.removeObject(forKey: Self.enabledKey) }
  }

  private static func defaultProfileStoreURL() -> URL {
    ApplicationSupport.directoryOrTrap()
      .appendingPathComponent("Dspeech", isDirectory: true)
      .appendingPathComponent("VoiceFilter", isDirectory: true)
      .appendingPathComponent(profileStoreFileName, isDirectory: false)
  }

  private func loadProfilesFromFileOrMigratedDefaults(
    decoder: JSONDecoder
  ) -> (profiles: [PilotVoiceProfile], issues: [VoiceFilterStorageIssue]) {
    if fileManager.fileExists(atPath: profileStoreURL.path) {
      do {
        let data = try Data(contentsOf: profileStoreURL)
        return (try decoder.decode([PilotVoiceProfile].self, from: data), [])
      } catch {
        return ([], [.profilesCorrupted])
      }
    }

    guard let legacyData = defaults.data(forKey: Self.profilesKey) else {
      return ([], [])
    }

    do {
      let migratedProfiles = try decoder.decode([PilotVoiceProfile].self, from: legacyData)
      try persistProfiles(migratedProfiles)
      defaults.removeObject(forKey: Self.profilesKey)
      return (migratedProfiles, [])
    } catch {
      return ([], [.profilesCorrupted])
    }
  }

  private func persistProfiles(_ profiles: [PilotVoiceProfile]) throws {
    let data = try JSONEncoder().encode(profiles)
    let directory = profileStoreURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    // why: set .complete at creation so the voiceprint file is never briefly readable at the
    // container-default class (completeUntilFirstUserAuthentication) in the window between the
    // write and applyVoiceProfileFileAttributes' setAttributes. The setAttributes call is kept
    // (belt-and-suspenders) so the protection-intent spy seam stays observable on the host.
    #if os(iOS)
      try data.write(to: profileStoreURL, options: [.atomic, .completeFileProtection])
    #else
      try data.write(to: profileStoreURL, options: .atomic)
    #endif
    try applyVoiceProfileFileAttributes(to: profileStoreURL)
  }

  private func applyVoiceProfileFileAttributes(to url: URL) throws {
    var attributeURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    #if os(iOS)
      try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.complete],
        ofItemAtPath: url.path
      )
    #endif
    try attributeURL.setResourceValues(values)
  }
}
