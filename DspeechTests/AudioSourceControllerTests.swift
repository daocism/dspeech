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

  @Test func routePreparationReadyRefreshesAvailableInputs() {
    let routing = FakeAudioSessionRouting(
      routePreparationStatus: .ready,
      currentRoute: RouteSnapshot(inputs: [port(.builtInMic, "Mic", "u-mic")]),
      availableInputs: [port(.builtInMic, "Mic", "u-mic"), port(.usbAudio, "USB", "u-usb")]
    )

    let controller = AudioSourceController(
      routing: routing, settings: AudioSettings(storage: InMemoryStorage()))

    #expect(controller.routePreparationFailure == nil)
    #expect(controller.availableInputs.map(\.uid) == ["u-mic", "u-usb"])
    #expect(controller.selectedUID == "u-mic")
    #expect(controller.hasSelectableInputs)
  }

  @Test func routePreparationFailureSurfacesAndDoesNotClaimInputs() {
    let routing = FakeAudioSessionRouting(
      routePreparationStatus: .failed(.recordCategoryUnavailable("category denied")),
      currentRoute: RouteSnapshot(inputs: [port(.builtInMic, "Mic", "u-mic")]),
      availableInputs: [port(.builtInMic, "Mic", "u-mic"), port(.usbAudio, "USB", "u-usb")]
    )
    let storage = InMemoryStorage()
    storage.uid = "u-usb"
    storage.type = "USBAudio"

    let controller = AudioSourceController(
      routing: routing, settings: AudioSettings(storage: storage))
    controller.applyPersistedPreference()
    controller.select(uid: "u-usb")

    #expect(controller.routePreparationFailure == .recordCategoryUnavailable("category denied"))
    let message = controller.routePreparationFailure?.userFacingMessage
    #expect(message?.contains("category denied") == true)
    #expect(controller.availableInputs.isEmpty)
    #expect(controller.selectedUID.isEmpty)
    #expect(!controller.hasSelectableInputs)
    #expect(routing.preferredInputCalls.isEmpty)
    #expect(storage.uid == "u-usb")
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

  @Test func applyPersistedPreferenceSurfacesRejectedInputAndKeepsCurrentRoute() {
    let storage = InMemoryStorage()
    storage.uid = "u-usb"
    storage.type = "USBAudio"
    let routing = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [port(.builtInMic, "Mic", "u-mic")]),
      availableInputs: [port(.builtInMic, "Mic", "u-mic"), port(.usbAudio, "USB", "u-usb")],
      rejectedPreferredInputUIDs: ["u-usb"]
    )
    let controller = AudioSourceController(
      routing: routing, settings: AudioSettings(storage: storage))

    controller.applyPersistedPreference()

    #expect(routing.preferredInputCalls == ["u-usb"])
    #expect(controller.selectedUID == "u-mic")
    #expect(controller.selectionError?.isEmpty == false)
    #expect(storage.uid == "u-usb")
  }

  @Test func selectRejectedInputDoesNotPersistOrClaimSelection() {
    let storage = InMemoryStorage()
    let routing = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [port(.builtInMic, "Mic", "u-mic")]),
      availableInputs: [port(.builtInMic, "Mic", "u-mic"), port(.usbAudio, "USB", "u-usb")],
      rejectedPreferredInputUIDs: ["u-usb"]
    )
    let controller = AudioSourceController(
      routing: routing, settings: AudioSettings(storage: storage))

    controller.select(uid: "u-usb")

    #expect(routing.preferredInputCalls == ["u-usb"])
    #expect(controller.selectedUID == "u-mic")
    #expect(controller.selectionError?.isEmpty == false)
    #expect(storage.uid == nil)
    #expect(storage.type == nil)
  }

  @Test func selectIgnoresUnknownUID() {
    let routing = FakeAudioSessionRouting(availableInputs: [port(.builtInMic, "Mic", "u-mic")])
    let controller = AudioSourceController(
      routing: routing, settings: AudioSettings(storage: InMemoryStorage()))
    controller.select(uid: "nonexistent")
    #expect(routing.preferredInputCalls.isEmpty)
  }

  final class FakeInputLevelMeter: InputLevelMetering, @unchecked Sendable {
    let eventsToEmit: [InputLevelMeterEvent]
    private(set) var stopCount = 0
    init(_ events: [InputLevelMeterEvent]) {
      self.eventsToEmit = events
    }
    convenience init(values: [Double]) {
      self.init(values.map(InputLevelMeterEvent.level))
    }
    func events() -> AsyncStream<InputLevelMeterEvent> {
      AsyncStream { continuation in
        for event in eventsToEmit { continuation.yield(event) }
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

  // why: hosted macOS runners can delay a new MainActor metering task while the rest of
  // DspeechTests are running in parallel. The timeout is a test-harness budget, not a
  // product invariant; shorter budgets caused retry-only flakes even though the fake meter
  // eventually delivered its deterministic events. Keep the assertion strict, but give CI enough
  // scheduler headroom so retries are not used as a timing crutch. The hosted Xcode 26.5
  // runner can cold-start many Swift Testing cases together, so keep this above the observed
  // 20s first-attempt stall while preserving strict final-state assertions.
  private func waitUntil(
    _ predicate: @MainActor () -> Bool, timeout: Duration = .seconds(30)
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
    #expect(controller.inputLevelError == nil)
  }

  @Test func startMeteringSurfacesFailureAndStopsMetering() async {
    let meter = FakeInputLevelMeter([.failed("meter failed")])
    let controller = makeController(meter: meter)

    controller.startMetering()

    await waitUntil { controller.inputLevelError == "meter failed" }
    #expect(controller.inputLevel == 0)
    #expect(controller.inputLevelError == "meter failed")
    #expect(!controller.isMetering)
    #expect(meter.stopCount >= 1)
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
