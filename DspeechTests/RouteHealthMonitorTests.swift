import Foundation
import Testing

@testable import Dspeech

#if canImport(AVFAudio)
  import AVFAudio
#endif

@MainActor
struct RouteHealthMonitorTests {
  private static func port(_ type: AudioPortType, name: String = "X") -> PortSnapshot {
    PortSnapshot(portType: type, portName: name)
  }

  @Test func initialAssessmentReflectsRouting() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.builtInMic, name: "iPhone Mic")]),
      availableInputs: [Self.port(.builtInMic, name: "iPhone Mic")]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    #expect(monitor.health == .cautionBuiltIn)
    #expect(monitor.primaryInputName == "iPhone Mic")
    #expect(!monitor.blocksStart)
  }

  @Test func blocksStartWhenNoInput() {
    let fake = FakeAudioSessionRouting()
    let monitor = RouteHealthMonitor(routing: fake)
    #expect(monitor.health == .noInput)
    #expect(monitor.blocksStart)
  }

  @Test func routePreparationFailureBlocksStartBeforeAvailableInputFallback() {
    let fake = FakeAudioSessionRouting(
      routePreparationStatus: .failed(.recordCategoryUnavailable("category denied")),
      currentRoute: RouteSnapshot(),
      availableInputs: [Self.port(.builtInMic, name: "iPhone Mic")]
    )
    let monitor = RouteHealthMonitor(routing: fake)

    #expect(monitor.health == .noInput)
    #expect(monitor.blocksStart)
    #expect(monitor.routePreparationFailure == .recordCategoryUnavailable("category denied"))
    #expect(monitor.primaryInputName == nil)
  }

  @Test func oldDeviceUnavailableFromExternalEmitsLostNotice() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    #expect(monitor.health == .suitableExternal)

    fake.updateRoute(
      RouteSnapshot(inputs: [Self.port(.builtInMic, name: "iPhone Mic")]),
      availableInputs: [Self.port(.builtInMic, name: "iPhone Mic")]
    )
    monitor.handle(event: .oldDeviceUnavailable)

    #expect(monitor.health == .cautionBuiltIn)
    #expect(monitor.lastNotice?.kind == .lost)
    #expect(monitor.lastNotice?.isUserVisible == true)
  }

  @Test func newDeviceAvailableEmitsImprovedNoticeWhenHealthClimbs() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.builtInMic, name: "iPhone Mic")]),
      availableInputs: [Self.port(.builtInMic, name: "iPhone Mic")]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    fake.updateRoute(
      RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    monitor.handle(event: .newDeviceAvailable)

    #expect(monitor.health == .suitableExternal)
    #expect(monitor.lastNotice?.kind == .improved)
    #expect(monitor.lastNotice?.portName == "USB Tap")
  }

  @Test func noSuitableRouteEmitsNoSuitableNotice() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.builtInMic)]),
      availableInputs: [Self.port(.builtInMic)]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    fake.updateRoute(RouteSnapshot(), availableInputs: [])
    monitor.handle(event: .noSuitableRouteForCategory)
    #expect(monitor.lastNotice?.kind == .noSuitableRoute)
    #expect(monitor.health == .noInput)
  }

  @Test func interruptionBeganBlocksStartAndShowsNotice() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    #expect(!monitor.blocksStart)

    monitor.handle(event: .interruptionBegan)

    #expect(monitor.isAudioSessionInterrupted)
    #expect(monitor.blocksStart)
    #expect(monitor.lastNotice?.kind == .interruptionBegan)
    #expect(monitor.lastNotice?.isUserVisible == true)
    #expect(monitor.lastNotice?.bannerText.isEmpty == false)
  }

  @Test func interruptionEndedUnblocksStartWhenRouteIsHealthy() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    monitor.handle(event: .interruptionBegan)
    #expect(monitor.blocksStart)

    monitor.handle(event: .interruptionEnded(shouldResume: true))

    #expect(!monitor.isAudioSessionInterrupted)
    #expect(!monitor.blocksStart)
    #expect(monitor.lastNotice?.kind == .interruptionEnded(shouldResume: true))
    #expect(monitor.lastNotice?.isUserVisible == true)
  }

  @Test func mediaServicesResetShowsVisibleNoticeAndRecomputesRoute() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    monitor.handle(event: .interruptionBegan)
    fake.updateRoute(
      RouteSnapshot(inputs: [Self.port(.builtInMic, name: "iPhone Mic")]),
      availableInputs: [Self.port(.builtInMic, name: "iPhone Mic")]
    )

    monitor.handle(event: .mediaServicesWereReset)

    #expect(!monitor.isAudioSessionInterrupted)
    #expect(monitor.health == .cautionBuiltIn)
    #expect(monitor.lastNotice?.kind == .mediaServicesReset)
    #expect(monitor.lastNotice?.isUserVisible == true)
    #expect(monitor.lastNotice?.portName == "iPhone Mic")
  }

  #if canImport(AVFAudio)
    @Test func interruptionUserInfoNSNumberValuesMapToRouteEvents() {
      let began = LiveAudioSessionRouting.event(
        forInterruptionUserInfo: [
          AVAudioSessionInterruptionTypeKey:
            NSNumber(value: AVAudioSession.InterruptionType.began.rawValue)
        ]
      )
      let endedWithoutResume = LiveAudioSessionRouting.event(
        forInterruptionUserInfo: [
          AVAudioSessionInterruptionTypeKey:
            NSNumber(value: AVAudioSession.InterruptionType.ended.rawValue)
        ]
      )
      let endedWithResume = LiveAudioSessionRouting.event(
        forInterruptionUserInfo: [
          AVAudioSessionInterruptionTypeKey:
            NSNumber(value: AVAudioSession.InterruptionType.ended.rawValue),
          AVAudioSessionInterruptionOptionKey:
            NSNumber(value: AVAudioSession.InterruptionOptions.shouldResume.rawValue),
        ]
      )

      #expect(began == .interruptionBegan)
      #expect(endedWithoutResume == .interruptionEnded(shouldResume: false))
      #expect(endedWithResume == .interruptionEnded(shouldResume: true))
    }
  #endif

  @Test func categoryChangeIsSilent() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.usbAudio)]),
      availableInputs: [Self.port(.usbAudio)]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    monitor.handle(event: .categoryChange)
    #expect(monitor.lastNotice?.kind == .silent)
    #expect(monitor.lastNotice?.isUserVisible == false)
    #expect(monitor.health == .suitableExternal)
  }

  @Test func displayCopyAvoidsCertifiedLanguage() {
    for health in [
      RouteHealth.suitableExternal,
      .cautionBuiltIn,
      .unsuitableOutputOnly,
      .unknownExternal,
      .noInput,
    ] {
      let label = health.displayLabel.lowercased()
      let short = health.shortLabel.lowercased()
      for forbidden in Self.forbiddenSubstrings {
        #expect(
          !label.contains(forbidden),
          "displayLabel for \(health) contained forbidden phrase \(forbidden)")
        #expect(
          !short.contains(forbidden),
          "shortLabel for \(health) contained forbidden phrase \(forbidden)")
      }
    }
  }

  @Test func bannerCopyAvoidsCertifiedLanguage() {
    let kinds: [RouteChangeNotice.Kind] = [
      .improved,
      .lost,
      .noSuitableRoute,
      .interruptionBegan,
      .interruptionEnded(shouldResume: true),
      .interruptionEnded(shouldResume: false),
      .mediaServicesReset,
      .silent,
    ]
    for kind in kinds {
      let notice = RouteChangeNotice(kind: kind, portName: "USB Tap", timestamp: Date())
      let banner = notice.bannerText.lowercased()
      for forbidden in Self.forbiddenSubstrings {
        #expect(
          !banner.contains(forbidden),
          "bannerText for \(kind) contained forbidden phrase \(forbidden)")
      }
    }
  }

  @Test func bannerTextIsEmptyForSilentNotice() {
    let notice = RouteChangeNotice(kind: .silent, portName: "X", timestamp: Date())
    #expect(notice.bannerText.isEmpty)
    #expect(notice.isUserVisible == false)
  }

  @Test func bannerTextIsNonEmptyForVisibleKinds() {
    for kind in [
      RouteChangeNotice.Kind.improved,
      .lost,
      .noSuitableRoute,
      .interruptionBegan,
      .interruptionEnded(shouldResume: true),
      .interruptionEnded(shouldResume: false),
      .mediaServicesReset,
    ] {
      let notice = RouteChangeNotice(kind: kind, portName: "USB Tap", timestamp: Date())
      #expect(
        !notice.bannerText.isEmpty,
        "bannerText empty for visible kind \(kind)")
      #expect(
        notice.isUserVisible == true,
        "isUserVisible false for \(kind)")
    }
  }

  @Test func blocksStartForNoInputAndOutputOnlyRoutes() {
    let cases: [(RouteSnapshot, [PortSnapshot], Bool)] = [
      (RouteSnapshot(), [], true),
      (
        RouteSnapshot(inputs: [Self.port(.builtInMic)]),
        [Self.port(.builtInMic)], false
      ),
      (
        RouteSnapshot(inputs: [Self.port(.usbAudio)]),
        [Self.port(.usbAudio)], false
      ),
      (
        RouteSnapshot(inputs: [Self.port(.unknown("X"))]),
        [Self.port(.unknown("X"))], false
      ),
      (
        RouteSnapshot(inputs: [Self.port(.bluetoothA2DP)]),
        [Self.port(.bluetoothA2DP)], true
      ),
      (
        RouteSnapshot(inputs: [Self.port(.airPlay)]),
        [Self.port(.airPlay)], true
      ),
    ]
    for (route, available, expectedBlocks) in cases {
      let fake = FakeAudioSessionRouting(
        currentRoute: route, availableInputs: available
      )
      let monitor = RouteHealthMonitor(routing: fake)
      #expect(
        monitor.blocksStart == expectedBlocks,
        "blocksStart wrong for health \(monitor.health)")
    }
  }

  @Test func newDeviceAvailableWithoutImprovementIsSilent() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    monitor.handle(event: .newDeviceAvailable)
    #expect(monitor.health == .suitableExternal)
    #expect(monitor.lastNotice?.kind == .silent)
    #expect(monitor.lastNotice?.isUserVisible == false)
  }

  @Test func newDeviceAvailableDownshiftIsSilent() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB Tap")]),
      availableInputs: [Self.port(.usbAudio, name: "USB Tap")]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    fake.updateRoute(
      RouteSnapshot(inputs: [Self.port(.builtInMic, name: "iPhone Mic")]),
      availableInputs: [Self.port(.builtInMic, name: "iPhone Mic")]
    )
    monitor.handle(event: .newDeviceAvailable)
    #expect(monitor.health == .cautionBuiltIn)
    #expect(monitor.lastNotice?.kind == .silent)
  }

  @Test func newDeviceAvailableOutputOnlyIsSilentAndStillBlocksStart() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(),
      availableInputs: []
    )
    let monitor = RouteHealthMonitor(routing: fake)
    fake.updateRoute(
      RouteSnapshot(inputs: [Self.port(.airPlay, name: "AirPlay Receiver")]),
      availableInputs: [Self.port(.airPlay, name: "AirPlay Receiver")]
    )

    monitor.handle(event: .newDeviceAvailable)

    #expect(monitor.health == .unsuitableOutputOnly)
    #expect(monitor.blocksStart)
    #expect(monitor.lastNotice?.kind == .silent)
    #expect(monitor.lastNotice?.isUserVisible == false)
  }

  @Test func oldDeviceUnavailableFromBuiltInIsSilent() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.builtInMic)]),
      availableInputs: [Self.port(.builtInMic)]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    monitor.handle(event: .oldDeviceUnavailable)
    #expect(monitor.lastNotice?.kind == .silent)
  }

  @Test func overrideEventIsSilentRecompute() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.usbAudio)]),
      availableInputs: [Self.port(.usbAudio)]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    fake.updateRoute(
      RouteSnapshot(inputs: [Self.port(.builtInMic)]),
      availableInputs: [Self.port(.builtInMic)]
    )
    monitor.handle(event: .override)
    #expect(monitor.lastNotice?.kind == .silent)
    #expect(monitor.health == .cautionBuiltIn)
    #expect(monitor.lastEvent == .override)
  }

  @Test func wakeFromSleepIsSilentRecompute() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.usbAudio)]),
      availableInputs: [Self.port(.usbAudio)]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    monitor.handle(event: .wakeFromSleep)
    #expect(monitor.lastNotice?.kind == .silent)
    #expect(monitor.health == .suitableExternal)
  }

  @Test func routeConfigurationChangeIsSilentRecompute() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.usbAudio)]),
      availableInputs: [Self.port(.usbAudio)]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    monitor.handle(event: .routeConfigurationChange)
    #expect(monitor.lastNotice?.kind == .silent)
  }

  @Test func unknownRawEventIsSilentRecompute() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.usbAudio)]),
      availableInputs: [Self.port(.usbAudio)]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    monitor.handle(event: .unknown(99))
    #expect(monitor.lastNotice?.kind == .silent)
    #expect(monitor.lastEvent == .unknown(99))
  }

  @Test func clearNoticeResetsBanner() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.builtInMic)]),
      availableInputs: [Self.port(.builtInMic)]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    fake.updateRoute(
      RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB")]),
      availableInputs: [Self.port(.usbAudio, name: "USB")]
    )
    monitor.handle(event: .newDeviceAvailable)
    #expect(monitor.lastNotice != nil)
    monitor.clearNotice()
    #expect(monitor.lastNotice == nil)
  }

  @Test func refreshFromRoutingPicksUpNewRoute() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.builtInMic)]),
      availableInputs: [Self.port(.builtInMic)]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    #expect(monitor.health == .cautionBuiltIn)
    fake.updateRoute(
      RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB")]),
      availableInputs: [Self.port(.usbAudio, name: "USB")]
    )
    monitor.refreshFromRouting()
    #expect(monitor.health == .suitableExternal)
    #expect(monitor.primaryInputName == "USB")
  }

  @Test func noticeTimestampUsesInjectedClock() {
    let fixed = Date(timeIntervalSince1970: 1_700_000_000)
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.builtInMic)]),
      availableInputs: [Self.port(.builtInMic)]
    )
    let monitor = RouteHealthMonitor(routing: fake, now: { fixed })
    fake.updateRoute(
      RouteSnapshot(inputs: [Self.port(.usbAudio, name: "USB")]),
      availableInputs: [Self.port(.usbAudio, name: "USB")]
    )
    monitor.handle(event: .newDeviceAvailable)
    #expect(monitor.lastNotice?.timestamp == fixed)
  }

  @Test func noSuitableRouteEmitsBlockingNotice() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.usbAudio)]),
      availableInputs: [Self.port(.usbAudio)]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    fake.updateRoute(RouteSnapshot(), availableInputs: [])
    monitor.handle(event: .noSuitableRouteForCategory)
    #expect(monitor.blocksStart)
    #expect(monitor.lastNotice?.isUserVisible == true)
  }

  @Test func bluetoothLEHealthBannerIsUserVisibleOnImprovement() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.builtInMic)]),
      availableInputs: [Self.port(.builtInMic)]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    fake.updateRoute(
      RouteSnapshot(inputs: [Self.port(.bluetoothLE, name: "LE Mic")]),
      availableInputs: [Self.port(.bluetoothLE, name: "LE Mic")]
    )
    monitor.handle(event: .newDeviceAvailable)
    #expect(monitor.health == .suitableExternal)
    #expect(monitor.lastNotice?.kind == .improved)
    #expect(monitor.lastNotice?.isUserVisible == true)
  }

  @Test func startAndStopAreIdempotent() {
    let fake = FakeAudioSessionRouting(
      currentRoute: RouteSnapshot(inputs: [Self.port(.builtInMic)]),
      availableInputs: [Self.port(.builtInMic)]
    )
    let monitor = RouteHealthMonitor(routing: fake)
    monitor.start()
    monitor.start()
    monitor.stop()
    monitor.stop()
  }

  private static let forbiddenSubstrings: [String] = [
    "certif",
    "guarantee",
    "radio link",
    "tower link",
    "faa",
    "easa",
  ]
}
