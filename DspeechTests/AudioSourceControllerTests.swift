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

  final class FakeInputLevelMeter: InputLevelMetering, @unchecked Sendable {
    let values: [Double]
    private(set) var stopCount = 0
    init(values: [Double]) { self.values = values }
    func levels() -> AsyncStream<Double> {
      AsyncStream { continuation in
        for value in values { continuation.yield(value) }
        continuation.finish()
      }
    }
    func stop() { stopCount += 1 }
  }

  private func makeController(meter: FakeInputLevelMeter) -> AudioSourceController {
    AudioSourceController(
      routing: FakeAudioSessionRouting(availableInputs: [port(.builtInMic, "Mic", "u-mic")]),
      settings: AudioSettings(storage: InMemoryStorage()),
      meter: meter)
  }

  private func waitUntil(
    _ predicate: @MainActor () -> Bool, timeout: Duration = .seconds(2)
  ) async {
    let deadline = ContinuousClock().now.advanced(by: timeout)
    while ContinuousClock().now < deadline {
      if predicate() { return }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  @Test func startMeteringPublishesLevels() async {
    let meter = FakeInputLevelMeter(values: [0.0, 0.5, 0.9])
    let controller = makeController(meter: meter)
    controller.startMetering()
    await waitUntil { controller.inputLevel == 0.9 }
    #expect(controller.inputLevel == 0.9)
  }

  @Test func stopMeteringStopsMeterAndResetsLevel() async {
    let meter = FakeInputLevelMeter(values: [0.5])
    let controller = makeController(meter: meter)
    controller.startMetering()
    await waitUntil { controller.inputLevel == 0.5 }
    controller.stopMetering()
    #expect(controller.inputLevel == 0)
    #expect(meter.stopCount >= 1)
  }
}
