import Foundation
import Testing

@testable import Dspeech

@MainActor
struct AudioSettingsTests {
  final class InMemoryStorage: AudioSettingsStorage, @unchecked Sendable {
    var uid: String?
    var type: String?
    func loadPreferredInputUID() -> String? { uid }
    func savePreferredInputUID(_ value: String?) { uid = value }
    func loadPreferredInputType() -> String? { type }
    func savePreferredInputType(_ value: String?) { type = value }
  }

  private func port(_ type: AudioPortType, _ name: String, _ uid: String) -> PortSnapshot {
    PortSnapshot(portType: type, portName: name, uid: uid)
  }

  @Test func defaultsToNoPreference() {
    let settings = AudioSettings(storage: InMemoryStorage())
    #expect(settings.preferredInputUID == nil)
    #expect(settings.preferredInputType == nil)
  }

  @Test func setPreferredPersists() {
    let storage = InMemoryStorage()
    let settings = AudioSettings(storage: storage)
    settings.setPreferred(uid: "uid-1", type: "USBAudio")
    #expect(settings.preferredInputUID == "uid-1")
    #expect(storage.uid == "uid-1")
    #expect(storage.type == "USBAudio")
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

  @Test func userDefaultsRoundTrip() {
    let suite = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let storage = UserDefaultsAudioSettingsStorage(defaults: defaults)

    #expect(storage.loadPreferredInputUID() == nil)
    storage.savePreferredInputUID("u1")
    storage.savePreferredInputType("USBAudio")
    #expect(storage.loadPreferredInputUID() == "u1")
    #expect(storage.loadPreferredInputType() == "USBAudio")

    storage.savePreferredInputUID(nil)
    #expect(storage.loadPreferredInputUID() == nil)
  }
}
