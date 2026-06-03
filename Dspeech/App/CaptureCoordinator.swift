import Foundation
import Observation

@MainActor
@Observable
final class CaptureCoordinator {
  let live: LiveTranscriptionViewModel
  let routeMonitor: RouteHealthMonitor

  private(set) var startBlockedMessage: String?
  private var routeObservation: Task<Void, Never>?
  private let routeChanges: AsyncStream<RouteChangeEvent>?

  init(
    live: LiveTranscriptionViewModel,
    routeMonitor: RouteHealthMonitor,
    routeChanges: AsyncStream<RouteChangeEvent>? = nil
  ) {
    self.live = live
    self.routeMonitor = routeMonitor
    self.routeChanges = routeChanges
  }

  var canStart: Bool { !routeMonitor.blocksStart }

  var captureSourceLabel: String { routeMonitor.health.displayLabel }
  var captureSourceShortLabel: String { routeMonitor.health.shortLabel }
  var primaryInputName: String? { routeMonitor.primaryInputName }

  var routeBanner: String? {
    if let failure = routeMonitor.routePreparationFailure {
      return failure.userFacingMessage
    }
    guard let notice = routeMonitor.lastNotice, notice.isUserVisible else { return nil }
    let text = notice.bannerText
    return text.isEmpty ? nil : text
  }

  func start() async {
    guard !routeMonitor.blocksStart else {
      startBlockedMessage =
        routeMonitor.routePreparationFailure?.userFacingMessage
        ?? CaptureCoordinator.blockedMessage(for: routeMonitor.health)
      return
    }
    startBlockedMessage = nil
    await live.start()
  }

  func stop() {
    live.stop()
  }

  func toggle() async {
    if live.canStopCurrentSession {
      stop()
    } else {
      await start()
    }
  }

  // why: F8 — when the app moves to the background we stop ASR cleanly rather than
  // capture covertly. Receive-only product, no UIBackgroundModes audio entitlement,
  // so this also matches what the OS would do on suspension, made explicit.
  func stopForBackground() {
    guard live.canStopCurrentSession else { return }
    live.stop()
  }

  func handleRouteEvent(_ event: RouteChangeEvent) {
    routeMonitor.handle(event: event)
    if routeMonitor.lastNotice?.kind == .lost, live.canStopCurrentSession {
      live.stop()
    }
  }

  func beginObservingRouteChanges() {
    guard routeObservation == nil, let routeChanges else { return }
    routeObservation = Task { @MainActor [weak self] in
      for await event in routeChanges {
        self?.handleRouteEvent(event)
      }
    }
  }

  func endObservingRouteChanges() {
    routeObservation?.cancel()
    routeObservation = nil
  }

  static func blockedMessage(for health: RouteHealth) -> String {
    switch health {
    case .noInput:
      return "Нет источника захвата — подключите вход и попробуйте снова."
    case .unsuitableOutputOnly:
      return "Доступен только вывод звука — подключите вход."
    default:
      return "Источник захвата недоступен — проверьте подключение входа."
    }
  }
}
