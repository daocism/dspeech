import Foundation
import Testing

@testable import Dspeech

// why: this suite shares the same MainActor fake live-engine contract as
// LiveTranscriptionViewModelTests; serialize it to avoid first-attempt hosted-CI scheduler
// starvation that only retries recover.
@Suite(.serialized)
@MainActor
struct CaptureCoordinatorTests {

  @MainActor
  final class FakeEngine: LiveTranscriptionEngine {
    var status: LiveTranscriptionStatus = .idle
    var startCallCount = 0
    var stopCallCount = 0
    var startSuspends = false
    private var continuation: AsyncStream<LiveTranscriptionEvent>.Continuation?
    private var pendingStartContinuation: CheckedContinuation<Void, Never>?

    init(startSuspends: Bool = false) {
      self.startSuspends = startSuspends
    }

    func events() -> AsyncStream<LiveTranscriptionEvent> {
      AsyncStream<LiveTranscriptionEvent> { continuation in
        self.continuation = continuation
        continuation.yield(.status(self.status))
      }
    }

    func start() async {
      startCallCount += 1
      status = .requestingPermission
      continuation?.yield(.status(.requestingPermission))
      if startSuspends {
        await withCheckedContinuation { continuation in
          pendingStartContinuation = continuation
        }
        guard status != .stopped else { return }
      }
      status = .listening
      continuation?.yield(.status(.listening))
    }

    func stop() {
      stopCallCount += 1
      status = .stopped
      continuation?.yield(.status(.stopped))
    }

    func completeStart() {
      let continuation = pendingStartContinuation
      pendingStartContinuation = nil
      continuation?.resume()
    }
  }

  private static func port(_ type: AudioPortType, name: String = "X") -> PortSnapshot {
    PortSnapshot(portType: type, portName: name)
  }

  private static func wait(
    for predicate: @MainActor () -> Bool,
    timeoutNs: UInt64 = 10_000_000_000
  ) async {
    let deadline = Date().addingTimeInterval(Double(timeoutNs) / 1_000_000_000.0)
    while Date() < deadline {
      if predicate() { return }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  private static func makeCoordinator(
    route: RouteSnapshot,
    availableInputs: [PortSnapshot],
    startSuspends: Bool = false
  ) -> (CaptureCoordinator, FakeEngine, FakeAudioSessionRouting) {
    let engine = FakeEngine(startSuspends: startSuspends)
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

  @Test func toggleWhileBlockedSurfacesMessageWithoutStartingEngine() async {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(),
      availableInputs: []
    )
    #expect(coordinator.canStart == false)

    await coordinator.toggle()

    #expect(engine.startCallCount == 0)
    #expect(coordinator.live.isListening == false)
    #expect(coordinator.startBlockedMessage != nil)
  }

  @Test func startBlockedByRoutePreparationFailureUsesTypedReason() async {
    let engine = FakeEngine()
    let routing = FakeAudioSessionRouting(
      routePreparationStatus: .failed(.recordCategoryUnavailable("category denied")),
      currentRoute: RouteSnapshot(),
      availableInputs: [Self.port(.builtInMic, name: "iPhone Mic")]
    )
    let live = LiveTranscriptionViewModel(engine: engine)
    let monitor = RouteHealthMonitor(routing: routing)
    let coordinator = CaptureCoordinator(live: live, routeMonitor: monitor)

    #expect(coordinator.canStart == false)
    #expect(coordinator.routeBanner?.contains("category denied") == true)

    await coordinator.start()

    #expect(engine.startCallCount == 0)
    #expect(coordinator.startBlockedMessage?.contains("category denied") == true)
  }

  @Test func startBlockedWhenRouteIsOutputOnly() async {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.airPlay, name: "AirPlay Receiver")]),
      availableInputs: [Self.port(.airPlay, name: "AirPlay Receiver")]
    )
    #expect(coordinator.routeMonitor.health == .unsuitableOutputOnly)
    #expect(coordinator.canStart == false)

    await coordinator.start()

    #expect(engine.startCallCount == 0)
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

  // why: regression — clearNotice() previously had no production call site, so an alarming
  // "External source lost — Recording paused" banner lingered over a healthy session forever.
  // A user-initiated (re)start must clear the stale notice.
  @Test func successfulStartClearsStaleRouteNotice() async {
    let (coordinator, engine, routing) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    routing.updateRoute(
      RouteSnapshot(inputs: [Self.port(.builtInMic, name: "iPhone Mic")]),
      availableInputs: [Self.port(.builtInMic, name: "iPhone Mic")]
    )
    coordinator.handleRouteEvent(.oldDeviceUnavailable)
    #expect(coordinator.routeMonitor.lastNotice?.kind == .lost)
    #expect(coordinator.routeBanner != nil)
    #expect(coordinator.canStart)

    await coordinator.start()
    await Self.wait(for: { coordinator.live.isListening })

    #expect(engine.startCallCount == 1)
    #expect(coordinator.routeMonitor.lastNotice == nil)
    #expect(coordinator.routeBanner == nil)
  }

  @Test func blockedStartDoesNotClearNotice() async {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(),
      availableInputs: []
    )
    coordinator.handleRouteEvent(.noSuitableRouteForCategory)
    #expect(coordinator.routeMonitor.lastNotice?.kind == .noSuitableRoute)
    #expect(coordinator.canStart == false)

    await coordinator.start()

    // why: a blocked start returns early without capturing — the notice must remain so the
    // user still sees why capture can't begin.
    #expect(engine.startCallCount == 0)
    #expect(coordinator.routeMonitor.lastNotice?.kind == .noSuitableRoute)
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

  @Test func interruptionBeganWhileListeningStopsAndShowsNotice() async {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    await coordinator.start()
    await Self.wait(for: { coordinator.live.isListening })

    coordinator.handleRouteEvent(.interruptionBegan)

    await Self.wait(for: { engine.stopCallCount == 1 })
    #expect(engine.stopCallCount == 1)
    #expect(coordinator.routeMonitor.isAudioSessionInterrupted)
    #expect(coordinator.canStart == false)
    #expect(coordinator.routeMonitor.lastNotice?.kind == .interruptionBegan)
    #expect(coordinator.routeBanner != nil)
  }

  @Test func interruptionEndedWithResumeRestartsWhenInterruptionStoppedCapture() async {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    await coordinator.start()
    await Self.wait(for: { coordinator.live.isListening })
    coordinator.handleRouteEvent(.interruptionBegan)
    await Self.wait(for: { engine.stopCallCount == 1 })

    coordinator.handleRouteEvent(.interruptionEnded(shouldResume: true))

    await Self.wait(for: { engine.startCallCount == 2 })
    #expect(engine.startCallCount == 2)
    #expect(engine.stopCallCount == 1)
  }

  @Test func interruptionEndedWithoutResumeDoesNotRestartAndClearsLatch() async {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    await coordinator.start()
    await Self.wait(for: { coordinator.live.isListening })
    coordinator.handleRouteEvent(.interruptionBegan)
    await Self.wait(for: { engine.stopCallCount == 1 })

    coordinator.handleRouteEvent(.interruptionEnded(shouldResume: false))
    coordinator.handleRouteEvent(.interruptionEnded(shouldResume: true))
    await Self.wait(for: {
      coordinator.routeMonitor.lastNotice?.kind == .interruptionEnded(shouldResume: true)
    })

    #expect(engine.startCallCount == 1)
    #expect(engine.stopCallCount == 1)
  }

  @Test func userStopClearsInterruptionResumeLatch() async {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    await coordinator.start()
    await Self.wait(for: { coordinator.live.isListening })
    coordinator.handleRouteEvent(.interruptionBegan)
    await Self.wait(for: { engine.stopCallCount == 1 })

    coordinator.stop()
    coordinator.handleRouteEvent(.interruptionEnded(shouldResume: true))
    await Self.wait(for: {
      coordinator.routeMonitor.lastNotice?.kind == .interruptionEnded(shouldResume: true)
    })

    #expect(engine.startCallCount == 1)
  }

  @Test func interruptionEndedWhileIdleShowsNoticeWithoutRestartingCapture() {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )

    coordinator.handleRouteEvent(.interruptionEnded(shouldResume: true))

    #expect(engine.startCallCount == 0)
    #expect(engine.stopCallCount == 0)
    #expect(coordinator.canStart)
    #expect(coordinator.routeMonitor.lastNotice?.kind == .interruptionEnded(shouldResume: true))
    #expect(coordinator.routeBanner != nil)
  }

  @Test func mediaServicesResetWhileListeningStopsAndShowsNotice() async {
    let (coordinator, engine, routing) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    await coordinator.start()
    await Self.wait(for: { coordinator.live.isListening })
    routing.updateRoute(
      RouteSnapshot(inputs: [Self.port(.builtInMic, name: "iPhone Mic")]),
      availableInputs: [Self.port(.builtInMic, name: "iPhone Mic")]
    )

    coordinator.handleRouteEvent(.mediaServicesWereReset)

    await Self.wait(for: { engine.stopCallCount == 1 })
    #expect(engine.stopCallCount == 1)
    #expect(coordinator.routeMonitor.health == .cautionBuiltIn)
    #expect(coordinator.routeMonitor.lastNotice?.kind == .mediaServicesReset)
    #expect(coordinator.routeBanner != nil)
  }

  @Test func noSuitableRouteWhileListeningStopsAndShowsNotice() async {
    let (coordinator, engine, routing) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    await coordinator.start()
    await Self.wait(for: { coordinator.live.isListening })
    routing.updateRoute(RouteSnapshot(), availableInputs: [])

    coordinator.handleRouteEvent(.noSuitableRouteForCategory)

    await Self.wait(for: { engine.stopCallCount == 1 })
    #expect(engine.stopCallCount == 1)
    #expect(coordinator.routeMonitor.health == .noInput)
    #expect(coordinator.routeMonitor.lastNotice?.kind == .noSuitableRoute)
    #expect(coordinator.routeBanner != nil)
  }

  @Test func oldDeviceUnavailableToNoInputStopsCapture() async {
    let (coordinator, engine, routing) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    await coordinator.start()
    await Self.wait(for: { coordinator.live.isListening })
    routing.updateRoute(RouteSnapshot(), availableInputs: [])

    coordinator.handleRouteEvent(.oldDeviceUnavailable)

    await Self.wait(for: { engine.stopCallCount == 1 })
    #expect(engine.stopCallCount == 1)
    #expect(coordinator.routeMonitor.health == .noInput)
    #expect(coordinator.routeMonitor.lastNotice?.kind == .noSuitableRoute)
  }

  @Test func mediaServicesResetWhileStoppedShowsNoticeWithoutStopCall() {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )

    coordinator.handleRouteEvent(.mediaServicesWereReset)

    #expect(engine.stopCallCount == 0)
    #expect(coordinator.routeMonitor.lastNotice?.kind == .mediaServicesReset)
    #expect(coordinator.routeBanner != nil)
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

  @Test func toggleStopsStartupInProgressInsteadOfStartingAgain() async {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio)]),
      availableInputs: [Self.port(.usbAudio)],
      startSuspends: true
    )
    let startTask = Task { @MainActor in await coordinator.toggle() }
    await Self.wait(for: { engine.startCallCount == 1 && coordinator.live.canStopCurrentSession })

    await coordinator.toggle()

    await Self.wait(for: { coordinator.live.status == .stopped })
    #expect(engine.startCallCount == 1)
    #expect(engine.stopCallCount == 1)
    #expect(coordinator.live.status == .stopped)

    engine.completeStart()
    await startTask.value
    #expect(coordinator.live.status == .stopped)
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

  @Test func stopForBackgroundSetsNoticeOnlyWhenCaptureWasActive() async {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio)]),
      availableInputs: [Self.port(.usbAudio)]
    )
    #expect(coordinator.stoppedForBackgroundNotice == false)

    coordinator.stopForBackground()
    #expect(engine.stopCallCount == 0)
    #expect(coordinator.stoppedForBackgroundNotice == false)

    await coordinator.start()
    await Self.wait(for: { coordinator.live.isListening })
    coordinator.stopForBackground()
    await Self.wait(for: { engine.stopCallCount == 1 })

    #expect(coordinator.stoppedForBackgroundNotice)
  }

  @Test func startAndUserStopClearBackgroundStopNotice() async {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio)]),
      availableInputs: [Self.port(.usbAudio)]
    )
    await coordinator.start()
    await Self.wait(for: { coordinator.live.isListening })
    coordinator.stopForBackground()
    await Self.wait(for: { engine.stopCallCount == 1 && coordinator.live.status == .stopped })
    #expect(coordinator.stoppedForBackgroundNotice)

    await coordinator.start()
    await Self.wait(for: { engine.startCallCount == 2 && coordinator.live.isListening })
    #expect(coordinator.live.isListening)
    #expect(coordinator.stoppedForBackgroundNotice == false)

    coordinator.stopForBackground()
    await Self.wait(for: { engine.stopCallCount == 2 })
    #expect(coordinator.stoppedForBackgroundNotice)

    coordinator.stop()
    #expect(coordinator.stoppedForBackgroundNotice == false)
  }

  @Test func stopForBackgroundIsNoOpWhenIdle() {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio)]),
      availableInputs: [Self.port(.usbAudio)]
    )
    coordinator.stopForBackground()
    #expect(engine.stopCallCount == 0)
  }

  @Test func refreshOnForegroundClearsStaleRouteBlock() {
    let (coordinator, _, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    coordinator.handleRouteEvent(.interruptionBegan)
    #expect(coordinator.canStart == false)

    coordinator.refreshOnForeground()

    #expect(coordinator.canStart)
    #expect(coordinator.startBlockedMessage == nil)
  }

  @Test func stopForBackgroundStopsStartupInProgress() async {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio)]),
      availableInputs: [Self.port(.usbAudio)],
      startSuspends: true
    )
    let startTask = Task { @MainActor in await coordinator.start() }
    await Self.wait(for: { engine.startCallCount == 1 && coordinator.live.canStopCurrentSession })

    coordinator.stopForBackground()

    await Self.wait(for: { coordinator.live.status == .stopped })
    #expect(engine.stopCallCount == 1)
    #expect(coordinator.live.status == .stopped)

    engine.completeStart()
    await startTask.value
    #expect(coordinator.live.status == .stopped)
  }

  @Test func routeLossStopsStartupInProgress() async {
    let (coordinator, engine, routing) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")],
      startSuspends: true
    )
    let startTask = Task { @MainActor in await coordinator.start() }
    await Self.wait(for: { engine.startCallCount == 1 && coordinator.live.canStopCurrentSession })

    routing.updateRoute(
      RouteSnapshot(inputs: [Self.port(.builtInMic, name: "iPhone Mic")]),
      availableInputs: [Self.port(.builtInMic, name: "iPhone Mic")]
    )
    coordinator.handleRouteEvent(.oldDeviceUnavailable)

    await Self.wait(for: { coordinator.live.status == .stopped })
    #expect(engine.stopCallCount == 1)
    #expect(coordinator.routeMonitor.lastNotice?.kind == .lost)
    #expect(coordinator.live.status == .stopped)

    engine.completeStart()
    await startTask.value
    #expect(coordinator.live.status == .stopped)
  }

  @Test func observingRouteChangesReceivesEventsAfterEndBeginCycle() async {
    let (coordinator, _, routing) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    coordinator.beginObservingRouteChanges()
    routing.emit(.categoryChange)
    await Self.wait(for: { coordinator.routeMonitor.lastEvent == .categoryChange })
    coordinator.endObservingRouteChanges()
    routing.updateRoute(RouteSnapshot(), availableInputs: [])
    coordinator.beginObservingRouteChanges()

    routing.emit(.noSuitableRouteForCategory)

    await Self.wait(for: { coordinator.routeMonitor.lastEvent == .noSuitableRouteForCategory })
    #expect(coordinator.routeMonitor.lastEvent == .noSuitableRouteForCategory)
    #expect(coordinator.routeMonitor.health == .noInput)
  }

  @Test func interruptionBeganStopsStartupInProgress() async {
    let (coordinator, engine, _) = Self.makeCoordinator(
      route: RouteSnapshot(inputs: [Self.port(.usbAudio)]),
      availableInputs: [Self.port(.usbAudio)],
      startSuspends: true
    )
    let startTask = Task { @MainActor in await coordinator.start() }
    await Self.wait(for: { engine.startCallCount == 1 && coordinator.live.canStopCurrentSession })

    coordinator.handleRouteEvent(.interruptionBegan)

    await Self.wait(for: { coordinator.live.status == .stopped })
    #expect(engine.stopCallCount == 1)
    #expect(coordinator.routeMonitor.isAudioSessionInterrupted)

    engine.completeStart()
    await startTask.value
    #expect(coordinator.live.status == .stopped)
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

  @Test func sameLanguageTranslationConflictUsesUnsupportedPairFailure() throws {
    let failure = try #require(
      ContentView.sameLanguageTranslationFailure(sourceIdentifier: "en-US", targetCode: "en"))

    #expect(
      failure
        == .languagePairingUnsupported(
          source: Locale.Language(identifier: "en-US"),
          target: Locale.Language(identifier: "en")))
    #expect(
      ContentView.sameLanguageTranslationFailure(sourceIdentifier: "fr-FR", targetCode: "en")
        == nil)
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
