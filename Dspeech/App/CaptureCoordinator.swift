import Foundation
import Observation

@MainActor
@Observable
final class CaptureCoordinator {
  let live: LiveTranscriptionViewModel
  let routeMonitor: RouteHealthMonitor

  private(set) var startBlockedMessage: String?
  private(set) var stoppedForBackgroundNotice = false
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
    stoppedForBackgroundNotice = false
    DspeechLog.routing.info(
      "capture start requested health=\(self.routeMonitor.health.rawValue, privacy: .public) blocksStart=\(self.routeMonitor.blocksStart, privacy: .public)"
    )
    guard !routeMonitor.blocksStart else {
      startBlockedMessage =
        routeMonitor.routePreparationFailure?.userFacingMessage
        ?? CaptureCoordinator.blockedMessage(for: routeMonitor.health)
      DspeechLog.routing.info(
        "capture start blocked health=\(self.routeMonitor.health.rawValue, privacy: .public)"
      )
      return
    }
    startBlockedMessage = nil
    // why: the user explicitly (re)started capture, acknowledging the current source. Clear any
    // stale route notice (e.g. "External source lost — Recording paused" after a reconnect) so an
    // alarming banner can't linger over a now-live session and contradict the route-health chip.
    // A genuinely new route problem during this session emits a fresh notice.
    routeMonitor.clearNotice()
    await live.start()
    DspeechLog.routing.info("capture start delegated to live engine")
  }

  func stop() {
    stoppedByInterruption = false
    stoppedForBackgroundNotice = false
    DspeechLog.routing.info("capture stop requested")
    live.stop()
  }

  func dismissStoppedForBackgroundNotice() {
    stoppedForBackgroundNotice = false
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
    stoppedForBackgroundNotice = true
    DspeechLog.routing.info("capture stopped for background")
    live.stop()
  }

  func refreshOnForeground() {
    DspeechLog.routing.info("capture foreground refresh requested")
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
    DspeechLog.routing.info(
      "capture coordinator route event event=\(String(describing: event), privacy: .public) wasCapturing=\(wasCapturing, privacy: .public)"
    )
    routeMonitor.handle(event: event)
    if case .interruptionBegan = event {
      if wasCapturing {
        stoppedByInterruption = true
        DspeechLog.routing.info("capture stopped for interruption began")
        live.stop()
      }
      return
    }
    if case .interruptionEnded(let shouldResume) = event {
      let shouldAutoResume = shouldResume && stoppedByInterruption
      DspeechLog.routing.info(
        "capture interruption ended shouldResume=\(shouldResume, privacy: .public) autoResume=\(shouldAutoResume, privacy: .public)"
      )
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
      DspeechLog.routing.info(
        "capture stopped for route event event=\(String(describing: event), privacy: .public) health=\(self.routeMonitor.health.rawValue, privacy: .public)"
      )
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
    DspeechLog.routing.info("capture coordinator began route observation")
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
    DspeechLog.routing.info("capture coordinator ended route observation")
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
