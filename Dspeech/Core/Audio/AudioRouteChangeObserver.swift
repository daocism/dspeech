import Foundation

/// Wraps route changes into an `AsyncStream<AudioRoute>`: each system route
/// change yields the now-active capture route as a pure domain ``AudioRoute``,
/// after the same trailing-debounce ``AppleAudioInputService/routeChanges()``
/// applies (rapid USB-C plug/pull bursts coalesce to one route-display update
/// instead of thrashing — closes `docs/handoff.md` W3-audio-tester escalation
/// #3 / autopilot `fp=9d12d5f9513b`).
///
/// This is the route-display feed. The frozen
/// ``AudioInputService/routeChanges()`` deliberately surfaces the richer
/// ``AudioRouteChange`` (reason + descriptor) for the picker; this surfaces the
/// pure ``AudioRoute`` for status display. Both consume the same architect-frozen
/// ``AudioInputSessionPort/routeChangeEvents()`` seam, so neither reads
/// `AVAudioSession` directly — the notification→route mapping and debounce are
/// pure Core and host-unit-testable with an injected fake port (this closes the
/// other half of testability escalation #1; the AVFoundation calls live only in
/// ``AVFoundationAudioInputSessionPort``, DocC-cited on ``AppleAudioInputService``).
///
/// `Sendable`: the injected port is `Sendable`, the debounce closure is
/// `@Sendable`; no AVFoundation type is held, so this file imports no
/// AVFoundation at all.
struct AudioRouteChangeObserver: Sendable {
    private let port: any AudioInputSessionPort
    private let debounce: Duration
    private let sleep: @Sendable (Duration) async -> Void

    init(
        port: any AudioInputSessionPort = AVFoundationAudioInputSessionPort(),
        debounce: Duration = AppleAudioInputService.defaultRouteDebounce,
        sleep: @escaping @Sendable (Duration) async -> Void = AppleAudioInputService.defaultSleep
    ) {
        self.port = port
        self.debounce = debounce
        self.sleep = sleep
    }

    func routes() -> AsyncStream<AudioRoute> {
        AppleAudioInputService.debounced(
            port.routeChangeEvents(),
            interval: debounce,
            sleep: sleep
        ) { event in
            event.activePort.map(AppleAudioInputService.route(from:))
        }
    }
}
