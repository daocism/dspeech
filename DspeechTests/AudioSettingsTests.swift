import Foundation
import Testing

@testable import Dspeech

@MainActor
struct AudioSettingsTests {
  enum TestError: Error {
    case saveFailed
  }

  final class InMemoryStorage: AudioSettingsStorage, @unchecked Sendable {
    var uid: String?
    var type: String?
    var failSaves = false
    func loadPreferredInputUID() -> String? { uid }
    func savePreferredInputUID(_ value: String?) throws {
      if failSaves { throw TestError.saveFailed }
      uid = value
    }
    func loadPreferredInputType() -> String? { type }
    func savePreferredInputType(_ value: String?) throws {
      if failSaves { throw TestError.saveFailed }
      type = value
    }
  }

  private func port(_ type: AudioPortType, _ name: String, _ uid: String) -> PortSnapshot {
    PortSnapshot(portType: type, portName: name, uid: uid)
  }

  @Test func defaultsToNoPreference() {
    let settings = AudioSettings(storage: InMemoryStorage())
    #expect(settings.preferredInputUID == nil)
    #expect(settings.preferredInputType == nil)
    #expect(settings.storageIssue == nil)
  }

  @Test func setPreferredPersists() {
    let storage = InMemoryStorage()
    let settings = AudioSettings(storage: storage)
    settings.setPreferred(uid: "uid-1", type: "USBAudio")
    #expect(settings.preferredInputUID == "uid-1")
    #expect(storage.uid == "uid-1")
    #expect(storage.type == "USBAudio")
    #expect(settings.storageIssue == nil)
  }

  @Test func setPreferredSaveFailureSurfacesStaleSettingsIssue() {
    let storage = InMemoryStorage()
    storage.failSaves = true
    let settings = AudioSettings(storage: storage)

    settings.setPreferred(uid: "uid-1", type: "USBAudio")

    #expect(settings.preferredInputUID == "uid-1")
    #expect(settings.preferredInputType == "USBAudio")
    #expect(storage.uid == nil)
    #expect(storage.type == nil)
    #expect(settings.storageIssue == .audioPreferredInputSaveFailed)
    #expect(settings.hasStaleSettings)
  }

  @Test func reflectsStoredOnInit() {
    let storage = InMemoryStorage()
    storage.uid = "uid-x"
    storage.type = "MicrophoneBuiltIn"
    let settings = AudioSettings(storage: storage)
    #expect(settings.preferredInputUID == "uid-x")
    #expect(settings.preferredInputType == "MicrophoneBuiltIn")
  }

  @Test func resolverPrefersExactUID() {
    let usb = port(.usbAudio, "USB", "u-usb")
    let mic = port(.builtInMic, "Mic", "u-mic")
    let resolved = PreferredInputResolver.resolve(
      uid: "u-usb", type: "MicrophoneBuiltIn", available: [mic, usb])
    #expect(resolved?.uid == "u-usb")
  }

  @Test func resolverFallsBackToType() {
    let mic = port(.builtInMic, "Mic", "u-mic")
    let resolved = PreferredInputResolver.resolve(
      uid: "gone", type: "MicrophoneBuiltIn", available: [mic])
    #expect(resolved?.uid == "u-mic")
  }

  @Test func resolverReturnsNilWhenNoMatch() {
    let mic = port(.builtInMic, "Mic", "u-mic")
    let resolved = PreferredInputResolver.resolve(uid: "x", type: "USBAudio", available: [mic])
    #expect(resolved == nil)
  }

  @Test func userDefaultsRoundTrip() throws {
    let suite = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let storage = UserDefaultsAudioSettingsStorage(defaults: defaults)

    #expect(storage.loadPreferredInputUID() == nil)
    try storage.savePreferredInputUID("u1")
    try storage.savePreferredInputType("USBAudio")
    #expect(storage.loadPreferredInputUID() == "u1")
    #expect(storage.loadPreferredInputType() == "USBAudio")

    try storage.savePreferredInputUID(nil)
    #expect(storage.loadPreferredInputUID() == nil)
  }

  @Test func userDefaultsBlankPersistedInputFallsBackToNilAndSurfacesIssue() {
    let suite = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let storage = UserDefaultsAudioSettingsStorage(defaults: defaults)

    defaults.set("", forKey: UserDefaultsAudioSettingsStorage.uidKey)

    #expect(storage.loadPreferredInputUID() == nil)
    #expect(storage.loadIssue() == .audioPreferredInputCorrupted)
  }
}
