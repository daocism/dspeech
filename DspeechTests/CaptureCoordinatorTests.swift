import Foundation
import Testing

@testable import Dspeech

@MainActor
struct CaptureCoordinatorTests {

  @MainActor
  final class FakeEngine: LiveTranscriptionEngine {
    var status: LiveTranscriptionStatus = .idle
    var startCallCount = 0
    var stopCallCount = 0
    private var continuation: AsyncStream<LiveTranscriptionEvent>.Continuation?

    func events() -> AsyncStream<LiveTranscriptionEvent> {
      AsyncStream<LiveTranscriptionEvent> { continuation in
        self.continuation = continuation
        continuation.yield(.status(self.status))
      }
    }

    func start() async {
      startCallCount += 1
      status = .listening
      continuation?.yield(.status(.listening))
    }

    func stop() {
      stopCallCount += 1
      status = .stopped
      continuation?.yield(.status(.stopped))
    }
  }

  private static func port(_ type: AudioPortType, name: String = "X") -> PortSnapshot {
    PortSnapshot(portType: type, portName: name)
  }

  private static func wait(
    for predicate: @MainActor () -> Bool,
    timeoutNs: UInt64 = 1_000_000_000
  ) async {
    let deadline = Date().addingTimeInterval(Double(timeoutNs) / 1_000_000_000.0)
    while Date() < deadline {
      if predicate() { return }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  private static func makeCoordinator(
    route: RouteSnapshot,
    availableInputs: [PortSnapshot]
  ) -> (CaptureCoordinator, FakeEngine, FakeAudioSessionRouting) {
    let engine = FakeEngine()
    let routing = FakeAudioSessionRouting(
      currentRoute: route,
      availableInputs: availableInputs
    )
    let live = LiveTranscriptionViewModel(engine: engine)
    let monitor = RouteHealthMonitor(routing: routing)
    let coordinator = CaptureCoordinator(live: live, routeMonitor: monitor)
    return (coordinator, engine, routing)
  }

  @Test func startBlockedWhenNoInput() async {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(),
      availableInputs: []
    )
    #expect(coordinator.routeMonitor.health == .noInput)
    #expect(coordinator.canStart == false)

    await coordinator.start()

    #expect(engine.startCallCount == 0)
    #expect(coordinator.live.isListening == false)
    #expect(coordinator.startBlockedMessage != nil)
  }

  @Test func startAllowedForCautionBuiltIn() async {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.builtInMic, name: "iPhone Mic")]),
      availableInputs: [Self.port(.builtInMic, name: "iPhone Mic")]
    )
    #expect(coordinator.routeMonitor.health == .cautionBuiltIn)
    #expect(coordinator.canStart)

    await coordinator.start()
    await Self.wait(for: { coordinator.live.isListening })

    #expect(engine.startCallCount == 1)
    #expect(coordinator.live.isListening)
    #expect(coordinator.startBlockedMessage == nil)
  }

  @Test func startAllowedForSuitableExternal() async {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    #expect(coordinator.routeMonitor.health == .suitableExternal)
    #expect(coordinator.canStart)

    await coordinator.start()
    await Self.wait(for: { coordinator.live.isListening })

    #expect(engine.startCallCount == 1)
  }

  @Test func oldDeviceUnavailableExternalToBuiltInStopsAndShowsNotice() async {
    let (coordinator, engine, routing) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    await coordinator.start()
    await Self.wait(for: { coordinator.live.isListening })
    #expect(engine.startCallCount == 1)

    routing.updateRoute(
      RouteSnapshot(inputs: [Self.port(.builtInMic, name: "iPhone Mic")]),
      availableInputs: [Self.port(.builtInMic, name: "iPhone Mic")]
    )
    coordinator.handleRouteEvent(.oldDeviceUnavailable)
    await Self.wait(for: { engine.stopCallCount == 1 })

    #expect(engine.stopCallCount == 1)
    #expect(coordinator.routeMonitor.lastNotice?.kind == .lost)
    #expect(coordinator.routeMonitor.lastNotice?.isUserVisible == true)
    #expect(coordinator.routeBanner != nil)
  }

  @Test func oldDeviceUnavailableWhenIdleDoesNotCallStop() {
    let (coordinator, engine, routing) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    routing.updateRoute(
      RouteSnapshot(inputs: [Self.port(.builtInMic, name: "iPhone Mic")]),
      availableInputs: [Self.port(.builtInMic, name: "iPhone Mic")]
    )
    coordinator.handleRouteEvent(.oldDeviceUnavailable)

    #expect(engine.stopCallCount == 0)
    #expect(coordinator.routeMonitor.lastNotice?.kind == .lost)
  }

  @Test func routeBannerNilForSilentNotice() {
    let (coordinator, _, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio)]),
      availableInputs: [Self.port(.usbAudio)]
    )
    coordinator.handleRouteEvent(.categoryChange)
    #expect(coordinator.routeMonitor.lastNotice?.kind == .silent)
    #expect(coordinator.routeBanner == nil)
  }

  @Test func toggleStopsWhenListening() async {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio)]),
      availableInputs: [Self.port(.usbAudio)]
    )
    await coordinator.toggle()
    await Self.wait(for: { coordinator.live.isListening })
    #expect(engine.startCallCount == 1)

    await coordinator.toggle()
    await Self.wait(for: { engine.stopCallCount == 1 })
    #expect(engine.stopCallCount == 1)
  }

  @Test func stopForBackgroundStopsWhenListening() async {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio)]),
      availableInputs: [Self.port(.usbAudio)]
    )
    await coordinator.start()
    await Self.wait(for: { coordinator.live.isListening })
    #expect(engine.startCallCount == 1)

    coordinator.stopForBackground()
    await Self.wait(for: { engine.stopCallCount == 1 })

    #expect(engine.stopCallCount == 1)
  }

  @Test func stopForBackgroundIsNoOpWhenIdle() {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio)]),
      availableInputs: [Self.port(.usbAudio)]
    )
    coordinator.stopForBackground()
    #expect(engine.stopCallCount == 0)
  }

  @Test func blockedMessageAvoidsForbiddenPhrases() {
    for health in [
      RouteHealth.suitableExternal,
      .cautionBuiltIn,
      .unsuitableOutputOnly,
      .unknownExternal,
      .noInput,
    ] {
      let message = CaptureCoordinator.blockedMessage(for: health).lowercased()
      for forbidden in Self.forbiddenSubstrings {
        #expect(
          !message.contains(forbidden),
          "blockedMessage for \(health) contained forbidden phrase \(forbidden)")
      }
    }
  }

  private static let forbiddenSubstrings: [String] = [
    "certif",
    "guarantee",
    "guaranteed",
    "radio link",
    "tower link",
    "faa",
    "easa",
  ]
}
