import Foundation
import Observation

@MainActor
@Observable
final class RouteHealthMonitor {
  private(set) var assessment: RouteHealthAssessment
  private(set) var lastNotice: RouteChangeNotice?
  private(set) var lastEvent: RouteChangeEvent?
  private(set) var routePreparationFailure: AudioRoutePreparationFailure?
  private(set) var isAudioSessionInterrupted = false

  private let routing: AudioSessionRouting
  private let now: @Sendable () -> Date
  private var observeTask: Task<Void, Never>?

  init(
    routing: AudioSessionRouting,
    now: @Sendable @escaping () -> Date = Date.init
  ) {
    self.routing = routing
    self.now = now
    self.routePreparationFailure = routing.routePreparationStatus.failure
    self.assessment = Self.assessment(for: routing)
  }

  var health: RouteHealth { assessment.health }
  var primaryInputName: String? { assessment.primaryInputName }
  var primaryInputTypeRaw: String? { assessment.primaryInputTypeRaw }
  var isCurrentRouteCaptureCapable: Bool {
    Self.isCaptureCapable(assessment: assessment, routePreparationFailure: routePreparationFailure)
  }

  var blocksStart: Bool {
    isAudioSessionInterrupted
      || routePreparationFailure != nil
      || assessment.health == .noInput
      || assessment.health == .unsuitableOutputOnly
  }

  func start() {
    if observeTask != nil { return }
    let stream = routing.routeChangeEvents()
    observeTask = Task { @MainActor [weak self] in
      for await event in stream {
        guard let self else { return }
        self.handle(event: event)
      }
    }
  }

  func stop() {
    observeTask?.cancel()
    observeTask = nil
  }

  func refreshFromRouting() {
    refreshFromRouting(clearStaleInterruption: false)
  }

  func refreshOnForeground() {
    refreshFromRouting(clearStaleInterruption: true)
  }

  func routeChangeEvents() -> AsyncStream<RouteChangeEvent> {
    routing.routeChangeEvents()
  }

  private func refreshFromRouting(clearStaleInterruption: Bool) {
    routePreparationFailure = routing.routePreparationStatus.failure
    assessment = Self.assessment(for: routing)
    if clearStaleInterruption, isCurrentRouteCaptureCapable {
      isAudioSessionInterrupted = false
    }
  }

  func handle(event: RouteChangeEvent) {
    lastEvent = event
    routePreparationFailure = routing.routePreparationStatus.failure
    let previous = assessment
    let recomputed = Self.assessment(for: routing)
    assessment = recomputed
    if event.clearsStaleInterruptionWhenHealthy,
      Self.isCaptureCapable(
        assessment: recomputed,
        routePreparationFailure: routePreparationFailure)
    {
      isAudioSessionInterrupted = false
    }

    switch event {
    case .newDeviceAvailable:
      if Self.didImprove(from: previous.health, to: recomputed.health) {
        lastNotice = RouteChangeNotice(
          kind: .improved,
          portName: recomputed.primaryInputName,
          timestamp: now()
        )
      } else {
        lastNotice = RouteChangeNotice(
          kind: .silent,
          portName: recomputed.primaryInputName,
          timestamp: now()
        )
      }
    case .oldDeviceUnavailable:
      if Self.isCaptureCapable(assessment: previous, routePreparationFailure: nil),
        !Self.isCaptureCapable(
          assessment: recomputed,
          routePreparationFailure: routePreparationFailure)
      {
        lastNotice = RouteChangeNotice(
          kind: .noSuitableRoute,
          portName: nil,
          timestamp: now()
        )
      } else if previous.health == .suitableExternal && recomputed.health != .suitableExternal {
        lastNotice = RouteChangeNotice(
          kind: .lost,
          portName: recomputed.primaryInputName,
          timestamp: now()
        )
      } else {
        lastNotice = RouteChangeNotice(
          kind: .silent,
          portName: recomputed.primaryInputName,
          timestamp: now()
        )
      }
    case .noSuitableRouteForCategory:
      lastNotice = RouteChangeNotice(
        kind: .noSuitableRoute,
        portName: nil,
        timestamp: now()
      )
    case .interruptionBegan:
      isAudioSessionInterrupted = true
      lastNotice = RouteChangeNotice(
        kind: .interruptionBegan,
        portName: recomputed.primaryInputName,
        timestamp: now()
      )
    case .interruptionEnded(let shouldResume):
      isAudioSessionInterrupted = false
      lastNotice = RouteChangeNotice(
        kind: .interruptionEnded(shouldResume: shouldResume),
        portName: recomputed.primaryInputName,
        timestamp: now()
      )
    case .mediaServicesWereReset:
      isAudioSessionInterrupted = false
      routePreparationFailure = routing.routePreparationStatus.failure
      assessment = Self.assessment(for: routing)
      lastNotice = RouteChangeNotice(
        kind: .mediaServicesReset,
        portName: assessment.primaryInputName,
        timestamp: now()
      )
    case .categoryChange, .override, .wakeFromSleep, .routeConfigurationChange, .unknown:
      if Self.isCaptureCapable(assessment: previous, routePreparationFailure: nil),
        !Self.isCaptureCapable(
          assessment: recomputed,
          routePreparationFailure: routePreparationFailure)
      {
        lastNotice = RouteChangeNotice(
          kind: .noSuitableRoute,
          portName: nil,
          timestamp: now()
        )
      } else {
        lastNotice = RouteChangeNotice(
          kind: .silent,
          portName: recomputed.primaryInputName,
          timestamp: now()
        )
      }
    }
  }

  func clearNotice() {
    lastNotice = nil
  }

  private static func didImprove(from old: RouteHealth, to new: RouteHealth) -> Bool {
    rank(new) > rank(old)
  }

  private static func isCaptureCapable(
    assessment: RouteHealthAssessment,
    routePreparationFailure: AudioRoutePreparationFailure?
  ) -> Bool {
    guard routePreparationFailure == nil else { return false }
    switch assessment.health {
    case .noInput, .unsuitableOutputOnly:
      return false
    case .suitableExternal, .cautionBuiltIn, .unknownExternal:
      return true
    }
  }

  private static func assessment(for routing: AudioSessionRouting) -> RouteHealthAssessment {
    guard routing.routePreparationStatus.failure == nil else {
      return RouteHealthAssessment(health: .noInput)
    }
    return RouteHealthClassifier.classify(
      route: routing.currentRouteSnapshot,
      availableInputs: routing.availableInputSnapshots
    )
  }

  private static func rank(_ h: RouteHealth) -> Int {
    switch h {
    case .noInput: return 0
    case .unsuitableOutputOnly: return 0
    case .unknownExternal: return 2
    case .cautionBuiltIn: return 3
    case .suitableExternal: return 4
    }
  }
}

extension RouteChangeEvent {
  fileprivate var clearsStaleInterruptionWhenHealthy: Bool {
    switch self {
    case .interruptionBegan, .interruptionEnded, .mediaServicesWereReset:
      return false
    case .newDeviceAvailable, .oldDeviceUnavailable, .categoryChange, .override, .wakeFromSleep,
      .noSuitableRouteForCategory, .routeConfigurationChange, .unknown:
      return true
    }
  }
}

extension RouteHealth {
  var displayLabel: String {
    switch self {
    case .suitableExternal: return String(localized: "External input")
    case .cautionBuiltIn: return String(localized: "iPhone microphone")
    case .unsuitableOutputOnly: return String(localized: "Output only — no input")
    case .unknownExternal: return String(localized: "Unknown input")
    case .noInput: return String(localized: "No input")
    }
  }

  var shortLabel: String {
    switch self {
    case .suitableExternal: return "EXT"
    case .cautionBuiltIn: return "MIC"
    case .unsuitableOutputOnly: return "OUT"
    case .unknownExternal: return "EXT?"
    case .noInput: return "—"
    }
  }
}

extension RouteChangeNotice {
  var bannerText: String {
    switch kind {
    case .improved:
      let source = portName ?? String(localized: "new input")
      return String(localized: "Capture source changed: \(source).")
    case .lost:
      let name = portName ?? String(localized: "built-in microphone")
      return String(localized: "External source lost — switching to \(name). Recording paused.")
    case .noSuitableRoute:
      return String(localized: "No suitable capture source.")
    case .interruptionBegan:
      return String(localized: "Audio capture was interrupted by the system. Recording paused.")
    case .interruptionEnded(let shouldResume):
      if shouldResume {
        return String(
          localized:
            "The audio session is available again. Restart capture after checking the input.")
      }
      return String(
        localized: "The audio session is available again. Check the input before starting again.")
    case .mediaServicesReset:
      return
        String(
          localized:
            "The iOS audio service restarted. Recording paused — check the input and start again.")
    case .silent:
      return ""
    }
  }

  var isUserVisible: Bool {
    switch kind {
    case .improved, .lost, .noSuitableRoute, .interruptionBegan, .interruptionEnded,
      .mediaServicesReset:
      return true
    case .silent: return false
    }
  }
}
