import Foundation
import Testing

@testable import Dspeech

@MainActor
struct AudioSourceControllerTests {
  final class InMemoryStorage: AudioSettingsStorage, @unchecked Sendable {
    var uid: String?
    var type: String?
    func loadPreferredInputUID() -> String? { uid }
    func savePreferredInputUID(_ value: String?) throws { uid = value }
    func loadPreferredInputType() -> String? { type }
    func savePreferredInputType(_ value: String?) throws { type = value }
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

  @Test func applyPersistedPreferenceAppliesPortTypeFallbackWhenUIDMissing() {
    let storage = InMemoryStorage()
    storage.uid = "old-usb"
    storage.type = "USBAudio"
    let routing = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [port(.builtInMic, "Mic", "u-mic")]),
      availableInputs: [port(.builtInMic, "Mic", "u-mic"), port(.usbAudio, "USB", "new-usb")]
    )
    let controller = AudioSourceController(
      routing: routing, settings: AudioSettings(storage: storage))

    controller.applyPersistedPreference()

    #expect(routing.preferredInputCalls == ["new-usb"])
    #expect(controller.selectedUID == "new-usb")
    #expect(storage.uid == "new-usb")
    #expect(storage.type == "USBAudio")
    #expect(controller.selectionError == nil)
  }

  @Test func applyPersistedPreferenceRejectedPortTypeFallbackKeepsCurrentRoute() {
    let storage = InMemoryStorage()
    storage.uid = "old-usb"
    storage.type = "USBAudio"
    let routing = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [port(.builtInMic, "Mic", "u-mic")]),
      availableInputs: [port(.builtInMic, "Mic", "u-mic"), port(.usbAudio, "USB", "new-usb")],
      rejectedPreferredInputUIDs: ["new-usb"]
    )
    let controller = AudioSourceController(
      routing: routing, settings: AudioSettings(storage: storage))

    controller.applyPersistedPreference()

    #expect(routing.preferredInputCalls == ["new-usb"])
    #expect(controller.selectedUID == "u-mic")
    #expect(controller.selectionError?.isEmpty == false)
    #expect(storage.uid == "old-usb")
    #expect(storage.type == "USBAudio")
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
    private let finishImmediately: Bool
    private(set) var eventsCallCount = 0
    private(set) var stopCount = 0
    init(_ events: [InputLevelMeterEvent], finishImmediately: Bool = true) {
      self.eventsToEmit = events
      self.finishImmediately = finishImmediately
    }
    convenience init(values: [Double]) {
      self.init(values.map(InputLevelMeterEvent.level))
    }
    func events() -> AsyncStream<InputLevelMeterEvent> {
      eventsCallCount += 1
      return AsyncStream { continuation in
        for event in eventsToEmit { continuation.yield(event) }
        if finishImmediately {
          continuation.finish()
        }
      }
    }
    func stop() { stopCount += 1 }
  }

  private func makeController(
    meter: FakeInputLevelMeter,
    arbiter: AudioCaptureArbiter = AudioCaptureArbiter()
  ) -> AudioSourceController {
    AudioSourceController(
      routing: FakeAudioSessionRouting(availableInputs: [port(.builtInMic, "Mic", "u-mic")]),
      settings: AudioSettings(storage: InMemoryStorage()),
      meter: meter,
      arbiter: arbiter)
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

  @Test func startMeteringWhenCaptureBusySurfacesFailureWithoutStartingMeter() {
    let arbiter = AudioCaptureArbiter()
    #expect(arbiter.acquire(.liveTranscription))
    let meter = FakeInputLevelMeter(values: [0.5])
    let controller = makeController(meter: meter, arbiter: arbiter)

    controller.startMetering()

    #expect(!controller.isMetering)
    #expect(controller.inputLevel == 0)
    #expect(
      controller.inputLevelError
        == "Audio capture is already in use. Stop transcription before testing the input level.")
    #expect(meter.eventsCallCount == 0)
    #expect(arbiter.activeClient == .liveTranscription)
  }

  // why: MEDIUM-2 — live transcription preempting the meter lease must IMMEDIATELY tear the meter
  // engine down (not wait for a manual stopMetering or rely on a UI invariant), so two
  // AVAudioEngines never tap the shared input. A late stopMetering must still not yank the lease
  // out from under the new live holder.
  @Test func livePreemptionImmediatelyStopsMeterAndKeepsLiveHolder() {
    let arbiter = AudioCaptureArbiter()
    let meter = FakeInputLevelMeter([], finishImmediately: false)
    let controller = makeController(meter: meter, arbiter: arbiter)

    controller.startMetering()
    #expect(arbiter.activeClient == .inputLevelMeter)
    #expect(controller.isMetering)

    #expect(arbiter.acquire(.liveTranscription))

    #expect(arbiter.activeClient == .liveTranscription)
    #expect(meter.stopCount >= 1)
    #expect(!controller.isMetering)

    controller.stopMetering()
    #expect(arbiter.activeClient == .liveTranscription)
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
