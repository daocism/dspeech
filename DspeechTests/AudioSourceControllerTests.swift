import Foundation
import Testing

@testable import Dspeech

@MainActor
struct AudioSourceControllerTests {
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

  @Test func selectPersistsAndSetsPreferredInput() {
    let routing = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [port(.builtInMic, "Mic", "u-mic")]),
      availableInputs: [port(.builtInMic, "Mic", "u-mic"), port(.usbAudio, "USB", "u-usb")]
    )
    let storage = InMemoryStorage()
    let controller = AudioSourceController(
      routing: routing, settings: AudioSettings(storage: storage))

    controller.select(uid: "u-usb")

    #expect(controller.selectedUID == "u-usb")
    #expect(storage.uid == "u-usb")
    #expect(storage.type == "USBAudio")
    #expect(routing.preferredInputCalls.contains("u-usb"))
  }

  @Test func refreshResolvesPersistedPreference() {
    let storage = InMemoryStorage()
    storage.uid = "u-usb"
    storage.type = "USBAudio"
    let routing = FakeAudioSessionRouting(
      availableInputs: [port(.builtInMic, "Mic", "u-mic"), port(.usbAudio, "USB", "u-usb")]
    )
    let controller = AudioSourceController(
      routing: routing, settings: AudioSettings(storage: storage))
    #expect(controller.selectedUID == "u-usb")
  }

  @Test func applyPersistedPreferenceSetsInputWhenAvailable() {
    let storage = InMemoryStorage()
    storage.uid = "u-usb"
    storage.type = "USBAudio"
    let routing = FakeAudioSessionRouting(availableInputs: [port(.usbAudio, "USB", "u-usb")])
    let controller = AudioSourceController(
      routing: routing, settings: AudioSettings(storage: storage))
    controller.applyPersistedPreference()
    #expect(routing.preferredInputCalls.contains("u-usb"))
  }

  @Test func selectIgnoresUnknownUID() {
    let routing = FakeAudioSessionRouting(availableInputs: [port(.builtInMic, "Mic", "u-mic")])
    let controller = AudioSourceController(
      routing: routing, settings: AudioSettings(storage: InMemoryStorage()))
    controller.select(uid: "nonexistent")
    #expect(routing.preferredInputCalls.isEmpty)
  }
}
