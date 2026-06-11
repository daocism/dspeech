import Foundation
import Observation

@MainActor
@Observable
final class CaptureCoordinator {
  let live: LiveTranscriptionViewModel
  let routeMonitor: RouteHealthMonitor

  private(set) var startBlockedMessage: String?
  private var routeObservation: Task<Void, Never>?
  private var stoppedByInterruption = false

  init(
    live: LiveTranscriptionViewModel,
    routeMonitor: RouteHealthMonitor
  ) {
    self.live = live
    self.routeMonitor = routeMonitor
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
    stoppedByInterruption = false
    guard !routeMonitor.blocksStart else {
      startBlockedMessage =
        routeMonitor.routePreparationFailure?.userFacingMessage
        ?? CaptureCoordinator.blockedMessage(for: routeMonitor.health)
      return
    }
    startBlockedMessage = nil
    // why: the user explicitly (re)started capture, acknowledging the current source. Clear any
    // stale route notice (e.g. "External source lost — Recording paused" after a reconnect) so an
    // alarming banner can't linger over a now-live session and contradict the route-health chip.
    // A genuinely new route problem during this session emits a fresh notice.
    routeMonitor.clearNotice()
    await live.start()
  }

  func stop() {
    stoppedByInterruption = false
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

  func refreshOnForeground() {
    routeMonitor.refreshOnForeground()
    if !routeMonitor.isAudioSessionInterrupted {
      stoppedByInterruption = false
    }
    if !routeMonitor.blocksStart {
      startBlockedMessage = nil
    }
  }

  func handleRouteEvent(_ event: RouteChangeEvent) {
    let wasCapturing = live.canStopCurrentSession
    routeMonitor.handle(event: event)
    if case .interruptionBegan = event {
      if wasCapturing {
        stoppedByInterruption = true
        live.stop()
      }
      return
    }
    if case .interruptionEnded(let shouldResume) = event {
      let shouldAutoResume = shouldResume && stoppedByInterruption
      stoppedByInterruption = false
      if shouldAutoResume {
        Task { @MainActor [weak self] in
          await self?.start()
        }
      }
      return
    }
    if shouldStopCurrentCapture(after: event), live.canStopCurrentSession {
      stoppedByInterruption = false
      live.stop()
    }
  }

  private func shouldStopCurrentCapture(after event: RouteChangeEvent) -> Bool {
    switch event {
    case .oldDeviceUnavailable:
      return routeMonitor.lastNotice?.kind == .lost || !routeMonitor.isCurrentRouteCaptureCapable
    case .mediaServicesWereReset:
      return true
    case .noSuitableRouteForCategory:
      return !routeMonitor.isCurrentRouteCaptureCapable
    case .newDeviceAvailable, .categoryChange, .override, .wakeFromSleep,
      .routeConfigurationChange, .unknown:
      return !routeMonitor.isCurrentRouteCaptureCapable
    case .interruptionBegan, .interruptionEnded:
      return false
    }
  }

  func beginObservingRouteChanges() {
    guard routeObservation == nil else { return }
    let routeChanges = routeMonitor.routeChangeEvents()
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
      return String(localized: "No capture source — connect an input and try again.")
    case .unsuitableOutputOnly:
      return String(localized: "Audio output only — connect an input.")
    default:
      return String(localized: "Capture source unavailable — check the input connection.")
    }
  }
}
