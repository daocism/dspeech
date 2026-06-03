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

  var blocksStart: Bool {
    isAudioSessionInterrupted
      || routePreparationFailure != nil
      || assessment.health == .noInput
      || assessment.health == .unsuitableOutputOnly
  }

  func start() {
    if observeTask != nil { return }
    let stream = routing.routeChanges
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
    routePreparationFailure = routing.routePreparationStatus.failure
    assessment = Self.assessment(for: routing)
  }

  func handle(event: RouteChangeEvent) {
    lastEvent = event
    routePreparationFailure = routing.routePreparationStatus.failure
    let previous = assessment
    let recomputed = Self.assessment(for: routing)
    assessment = recomputed

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
      if previous.health == .suitableExternal && recomputed.health != .suitableExternal {
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
      lastNotice = RouteChangeNotice(
        kind: .silent,
        portName: recomputed.primaryInputName,
        timestamp: now()
      )
    }
  }

  func clearNotice() {
    lastNotice = nil
  }

  private static func didImprove(from old: RouteHealth, to new: RouteHealth) -> Bool {
    rank(new) > rank(old)
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

extension RouteHealth {
  var displayLabel: String {
    switch self {
    case .suitableExternal: return "Внешний вход"
    case .cautionBuiltIn: return "Микрофон iPhone"
    case .unsuitableOutputOnly: return "Только вывод — нет входа"
    case .unknownExternal: return "Неизвестный вход"
    case .noInput: return "Нет входа"
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
      return "Источник захвата сменился: \(portName ?? "новый вход")."
    case .lost:
      let name = portName ?? "встроенный микрофон"
      return "Внешний источник пропал — переключение на \(name). Запись приостановлена."
    case .noSuitableRoute:
      return "Нет подходящего источника захвата."
    case .interruptionBegan:
      return "Аудиозахват прерван системой. Запись приостановлена."
    case .interruptionEnded(let shouldResume):
      if shouldResume {
        return "Аудиосессия снова доступна. Запустите захват заново после проверки входа."
      }
      return "Аудиосессия снова доступна. Проверьте вход перед новым запуском."
    case .mediaServicesReset:
      return
        "Аудиосервис iOS перезапущен. Запись приостановлена — проверьте вход и запустите снова."
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
