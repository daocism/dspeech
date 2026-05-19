@preconcurrency import AVFoundation
import Foundation

/// Wraps `AVAudioSession.routeChangeNotification` into an
/// `AsyncStream<AudioRoute>`: each system route change yields the now-active
/// capture route as a pure domain ``AudioRoute``.
///
/// This is the role-mandated low-level building block. The frozen
/// ``AudioInputService/routeChanges()`` deliberately surfaces the richer
/// ``AudioRouteChange`` (reason + descriptor) — it is implemented in
/// `AppleAudioInputService` rather than here, because losing the
/// `newDeviceAvailable`/`oldDeviceUnavailable` reason at that boundary would
/// degrade the architecture's "re-list on USB-C plug/pull" behavior
/// (`docs/architecture-mvp-slice-2026-05-19.md` "Data flow per gate", F5). Both
/// subscribe to the same multicast `NotificationCenter` name independently.
///
/// ## API verification
/// Context7 MCP unmounted in the mac24 headless env → verified against Apple
/// official DocC JSON on 2026-05-19 (per `CLAUDE.md` "fetch current docs", as
/// W1 recorded in `docs/handoff.md`). DocC path = library-id equivalent:
/// - `documentation/avfaudio/avaudiosession/routechangenotification` —
///   `class let routeChangeNotification: NSNotification.Name` (iOS 6, posted on
///   a secondary thread; the `AsyncStream` bridges it to the consumer's actor).
/// - `documentation/foundation/notificationcenter/notifications(named:object:)`
///   — `@preconcurrency func notifications(named:object:) -> Notifications`
///   (iOS 15); `object` left `nil` (route changes are single-session).
/// - `documentation/avfaudio/avaudiosession/currentroute` +
///   `documentation/avfaudio/avaudiosessionroutedescription/inputs` —
///   `currentRoute.inputs: [AVAudioSessionPortDescription]` (iOS 6); mapped to
///   ``AudioRoute`` via `AppleAudioInputService.route(from:)`.
struct AudioRouteChangeObserver: Sendable {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func routes() -> AsyncStream<AudioRoute> {
        AsyncStream<AudioRoute> { continuation in
            let session = self.session
            let task = Task {
                let notifications = NotificationCenter.default.notifications(
                    named: AVAudioSession.routeChangeNotification
                )
                for await _ in notifications {
                    if let port = session.currentRoute.inputs.first {
                        continuation.yield(AppleAudioInputService.route(from: port))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
