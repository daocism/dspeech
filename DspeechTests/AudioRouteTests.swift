import Foundation
import Testing
@testable import Dspeech

/// `AudioRoute` enum + `AudioRouteChangeObserver` + the frozen
/// `AudioInputService.routeChanges()` mapping (PRD F5 live picker refresh).
///
/// Everything below `AudioRoute` is RED until the W3 audio implementer lands
/// `AudioRoute.swift` / `AudioRouteChangeObserver.swift` / `AudioInputService.swift`
/// against the contract documented in `FakeAVAudioSession.swift`.
///
/// Real USB-C / Bluetooth route plug-and-pull is **device-only** — the iOS
/// Simulator fabricates routes (PLAN-2026-05-19 residual risk; W1 handoff).
/// These tests pin the *debounce / lifecycle / mapping* behaviour, which is
/// device-independent; physical-route validation stays Andrei-gated.
struct AudioRouteTests {

    private actor RouteCollector {
        private(set) var routes: [AudioRoute] = []
        func append(_ route: AudioRoute) { routes.append(route) }
        var count: Int { routes.count }
        var last: AudioRoute? { routes.last }
    }

    private actor ChangeCollector {
        private(set) var changes: [AudioRouteChange] = []
        func append(_ change: AudioRouteChange) { changes.append(change) }
        var last: AudioRouteChange? { changes.last }
    }

    private func waitUntil(
        _ predicate: @Sendable () async -> Bool,
        timeoutNs: UInt64 = 3_000_000_000
    ) async {
        let deadline = Date().addingTimeInterval(Double(timeoutNs) / 1_000_000_000)
        while Date() < deadline {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - AudioRoute enum (RED until AudioRoute.swift)

    @Test func routeEquatableDistinguishesCasesAndAssociatedNames() {
        #expect(AudioRoute.builtInMic == AudioRoute.builtInMic)
        #expect(AudioRoute.builtInMic != AudioRoute.wiredHeadset)
        #expect(AudioRoute.externalUSB(name: "A") == AudioRoute.externalUSB(name: "A"))
        #expect(AudioRoute.externalUSB(name: "A") != AudioRoute.externalUSB(name: "B"))
        #expect(AudioRoute.bluetooth(name: "AirPods") != AudioRoute.externalUSB(name: "AirPods"))
    }

    // MARK: - AudioRouteChangeObserver (RED until AudioRouteChangeObserver.swift)

    @Test func observerCoalescesRapidRouteBurstToFinalRoute() async {
        let fake = FakeAVAudioSession()
        let observer = AudioRouteChangeObserver(session: fake)
        let collector = RouteCollector()

        let consumer = Task {
            for await route in observer.routes() {
                await collector.append(route)
            }
        }
        defer { consumer.cancel() }

        let burst: [AudioRoute] = [
            .externalUSB(name: "Iface-1"),
            .bluetooth(name: "AirPods"),
            .wiredHeadset,
            .externalUSB(name: "Iface-2"),
        ]
        for route in burst { fake.pushRoute(route) }

        await waitUntil { await collector.last == .externalUSB(name: "Iface-2") }

        let observed = await collector.count
        #expect(await collector.last == .externalUSB(name: "Iface-2"))
        #expect(observed >= 1)
        #expect(observed < burst.count, "rapid burst must be debounced, not replayed 1:1")
    }

    @Test func observerKeepsUpstreamLiveAcrossRouteChangeDuringActiveCapture() async {
        let fake = FakeAVAudioSession()
        let observer = AudioRouteChangeObserver(session: fake)
        let collector = RouteCollector()

        let consumer = Task {
            for await route in observer.routes() {
                await collector.append(route)
            }
        }
        defer { consumer.cancel() }

        fake.pushRoute(.externalUSB(name: "Cockpit-USB"))
        await waitUntil { await collector.last == .externalUSB(name: "Cockpit-USB") }

        fake.pushRoute(.wiredHeadset)
        await waitUntil { await collector.last == .wiredHeadset }

        #expect(await collector.last == .wiredHeadset)
        #expect(
            fake.routeChangesContinuationFinished == false,
            "a route change must not tear down the live capture route stream"
        )
    }

    @Test func observerStopsUpstreamObservationWhenConsumerCancelled() async {
        let fake = FakeAVAudioSession()
        let observer = AudioRouteChangeObserver(session: fake)
        let collector = RouteCollector()

        let consumer = Task {
            for await route in observer.routes() {
                await collector.append(route)
            }
        }

        fake.pushRoute(.externalUSB(name: "USB"))
        await waitUntil { await collector.count >= 1 }

        consumer.cancel()

        await waitUntil { fake.routeChangesContinuationFinished }
        #expect(
            fake.routeChangesContinuationFinished,
            "cancelling the consumer must remove the AVAudioSession route observer (no leak)"
        )
    }

    // MARK: - AudioInputService.routeChanges() mapping (RED until AudioInputService.swift)

    @Test func serviceRouteChangesMapsRouteBucketToActiveInputKind() async throws {
        let usb = FakeAVAudioSession.usbDescriptor(name: "Cockpit-USB")
        let fake = FakeAVAudioSession(scriptedInputs: [usb])
        let service = AppleAudioInputService(session: fake)
        let collector = ChangeCollector()

        let consumer = Task {
            for await change in service.routeChanges() {
                await collector.append(change)
            }
        }
        defer { consumer.cancel() }

        fake.pushRoute(.externalUSB(name: "Cockpit-USB"))

        await waitUntil { await collector.last?.activeInput?.kind == .wired }
        let last = try #require(await collector.last)
        #expect(last.activeInput?.kind == .wired)
        #expect(last.reason == .newDeviceAvailable)
    }

    @Test func serviceRouteChangesFallsBackToBuiltInWhenNoInputAvailable() async throws {
        let fake = FakeAVAudioSession(scriptedInputs: [])
        let service = AppleAudioInputService(session: fake)
        let collector = ChangeCollector()

        let consumer = Task {
            for await change in service.routeChanges() {
                await collector.append(change)
            }
        }
        defer { consumer.cancel() }

        fake.pushRoute(.builtInMic)

        await waitUntil { await collector.last?.activeInput?.kind == .builtInMicrophone }
        let last = try #require(await collector.last)
        #expect(last.activeInput?.kind == .builtInMicrophone)
    }
}
