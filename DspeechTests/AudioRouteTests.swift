import AVFoundation
import Foundation
import Testing
@testable import Dspeech

/// `AudioRoute` domain enum + the frozen `AudioInputService.routeChanges()`
/// contract.
///
/// `AudioRoute` and its `displayName` are pure value logic in W3's
/// `AudioRoute.swift` — genuinely host-testable and tested here directly.
///
/// `AudioRouteChangeObserver` / `AppleAudioInputService.routeChanges()` wrap
/// `AVAudioSession.routeChangeNotification` + `session.currentRoute.inputs` with
/// no fakeable seam, so their notification→route mapping, the
/// dispatch-required **debounce of rapid route changes**, and observer
/// cancellation are **device-only** and additionally blocked on a testability
/// fix — both escalated in `docs/handoff.md` (W3 audio tester block). They are
/// deliberately not faked here: faking a stand-in would assert nothing about the
/// shipped code.
struct AudioRouteTests {

    // MARK: - AudioRoute (pure; W3 impl widened the dispatch's 4 cases to 5)

    @Test func routeEquatableDistinguishesCasesAndAssociatedNames() {
        #expect(AudioRoute.builtInMic == AudioRoute.builtInMic)
        #expect(AudioRoute.builtInMic != AudioRoute.wiredHeadset)
        #expect(AudioRoute.externalUSB(name: "A") == AudioRoute.externalUSB(name: "A"))
        #expect(AudioRoute.externalUSB(name: "A") != AudioRoute.externalUSB(name: "B"))
        #expect(AudioRoute.bluetooth(name: "AirPods") != AudioRoute.externalUSB(name: "AirPods"))
        #expect(AudioRoute.other(name: "CarPlay") != AudioRoute.other(name: "AirPlay"))
        #expect(AudioRoute.other(name: "CarPlay") != AudioRoute.bluetooth(name: "CarPlay"))
    }

    @Test func routeDisplayNameUsesDeviceNameWhenPresentBucketLabelOtherwise() {
        #expect(AudioRoute.externalUSB(name: "Behringer UMC202HD").displayName == "Behringer UMC202HD")
        #expect(AudioRoute.bluetooth(name: "AirPods Pro").displayName == "AirPods Pro")
        #expect(AudioRoute.other(name: "CarPlay").displayName == "CarPlay")
        #expect(AudioRoute.builtInMic.displayName.isEmpty == false)
        #expect(AudioRoute.wiredHeadset.displayName.isEmpty == false)
        #expect(AudioRoute.builtInMic.displayName != AudioRoute.wiredHeadset.displayName)
    }

    // MARK: - AudioRouteChange / AudioRouteChangeReason (frozen value types)

    @Test func routeChangeEquatableConsidersReasonAndActiveInput() {
        let usb = FakeAVAudioSession.usbDescriptor()
        let a = AudioRouteChange(reason: .newDeviceAvailable, activeInput: usb)
        let b = AudioRouteChange(reason: .newDeviceAvailable, activeInput: usb)
        let differentReason = AudioRouteChange(reason: .oldDeviceUnavailable, activeInput: usb)
        let differentInput = AudioRouteChange(reason: .newDeviceAvailable, activeInput: nil)

        #expect(a == b)
        #expect(a != differentReason)
        #expect(a != differentInput)
    }

    @Test(arguments: [
        AudioRouteChangeReason.newDeviceAvailable,
        .oldDeviceUnavailable,
        .categoryChange,
        .override,
        .configurationChange,
        .unknown,
    ])
    func routeChangeReasonRoundTripsThroughRawValue(reason: AudioRouteChangeReason) {
        #expect(AudioRouteChangeReason(rawValue: reason.rawValue) == reason)
    }

    // MARK: - Frozen routeChanges() contract (via the sanctioned fake seam)

    @Test func contractRouteChangeStreamDeliversEmittedChanges() async {
        let usb = FakeAVAudioSession.usbDescriptor(name: "Cockpit-USB")
        let fake = FakeAVAudioSession(scriptedInputs: [usb])

        let collected = TestBox<[AudioRouteChange]>([])
        let consumer = Task {
            for await change in fake.routeChanges() {
                collected.mutate { $0.append(change) }
            }
        }
        defer { consumer.cancel() }

        try? await Task.sleep(nanoseconds: 20_000_000)
        fake.emitRouteChange(AudioRouteChange(reason: .newDeviceAvailable, activeInput: usb))

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, collected.value.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(collected.value.last?.activeInput == usb)
        #expect(collected.value.last?.reason == .newDeviceAvailable)
    }

    @Test func contractRouteChangeStreamTerminatesOnConsumerCancellation() async {
        let fake = FakeAVAudioSession()
        let consumer = Task {
            for await _ in fake.routeChanges() {}
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
        consumer.cancel()

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !fake.routeStreamTerminated {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(fake.routeStreamTerminated)
    }

    // MARK: - routeChanges() orchestration over the injected AudioInputSessionPort seam
    //
    // The architect's "Adapter contract" DocC
    // (`AudioInputServiceProtocol.swift:236`) makes reason-code mapping AND the
    // missing **rapid-change debounce** pure-Core and host-testable for the
    // first time (closes handoff escalations #1 and #3). These specs construct
    // `AppleAudioInputService` over an injected `FakeAudioInputSessionPort` and
    // drive raw `AudioRouteChangeEvent`s. Apple `RouteChangeReason` raw values
    // are read from AVFoundation, never guessed (CLAUDE.md anti-hallucination).
    // Seam contract required of the W3a implementer remediation
    // (fp=9d12d5f9513b):
    //   init(port: AudioInputSessionPort,
    //        routeDebounce: Duration = .milliseconds(300),
    //        sleep: @Sendable (Duration) async -> Void = <real Task.sleep>)
    // RED until that initializer exists (intended red-first).

    private func firstRouteChange(
        from service: AppleAudioInputService,
        emitting emit: @escaping () -> Void,
        timeout: TimeInterval = 3
    ) async -> AudioRouteChange? {
        let collected = TestBox<[AudioRouteChange]>([])
        let consumer = Task {
            for await change in service.routeChanges() {
                collected.mutate { $0.append(change) }
            }
        }
        defer { consumer.cancel() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        emit()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, collected.value.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return collected.value.first
    }

    @Test func contractMapsEachAppleRouteChangeReasonOntoItsCoreReason() async {
        let table: [(AVAudioSession.RouteChangeReason, AudioRouteChangeReason)] = [
            (.newDeviceAvailable, .newDeviceAvailable),
            (.oldDeviceUnavailable, .oldDeviceUnavailable),
            (.categoryChange, .categoryChange),
            (.override, .override),
            (.routeConfigurationChange, .configurationChange),
            (.unknown, .unknown),
            (.wakeFromSleep, .unknown),
            (.noSuitableRouteForCategory, .unknown),
        ]
        for (appleReason, expected) in table {
            let fake = FakeAudioInputSessionPort()
            let service = AppleAudioInputService(port: fake, routeDebounce: .milliseconds(10))
            let change = await firstRouteChange(from: service) {
                fake.emitRouteEvent(
                    AudioRouteChangeEvent(reasonRawValue: appleReason.rawValue, activePort: nil)
                )
            }
            #expect(change?.reason == expected)
        }
    }

    @Test func contractMapsAbsentReasonKeyToUnknownNotADroppedEvent() async {
        let fake = FakeAudioInputSessionPort()
        let service = AppleAudioInputService(port: fake, routeDebounce: .milliseconds(10))
        let change = await firstRouteChange(from: service) {
            fake.emitRouteEvent(AudioRouteChangeEvent(reasonRawValue: nil, activePort: nil))
        }
        #expect(change?.reason == .unknown)
    }

    @Test func contractMapsUnrepresentableReasonRawValueToUnknown() async {
        let fake = FakeAudioInputSessionPort()
        let service = AppleAudioInputService(port: fake, routeDebounce: .milliseconds(10))
        let change = await firstRouteChange(from: service) {
            fake.emitRouteEvent(AudioRouteChangeEvent(reasonRawValue: UInt.max, activePort: nil))
        }
        #expect(change?.reason == .unknown)
    }

    @Test func contractMapsActivePortSnapshotIntoTheRouteChangeDescriptor() async {
        let usb = FakeAudioInputSessionPort.usbSnapshot(uid: "rc-usb", name: "Cockpit-USB")
        let fake = FakeAudioInputSessionPort()
        let service = AppleAudioInputService(port: fake, routeDebounce: .milliseconds(10))

        let change = await firstRouteChange(from: service) {
            fake.emitRouteEvent(
                AudioRouteChangeEvent(
                    reasonRawValue: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
                    activePort: usb
                )
            )
        }

        #expect(change?.reason == .newDeviceAvailable)
        #expect(change?.activeInput?.id == "rc-usb")
        #expect(change?.activeInput?.kind == .wired)
        #expect(change?.activeInput?.displayName == "Cockpit-USB")
    }

    @Test func contractMapsNilActivePortToNilActiveInput() async {
        let fake = FakeAudioInputSessionPort()
        let service = AppleAudioInputService(port: fake, routeDebounce: .milliseconds(10))
        let change = await firstRouteChange(from: service) {
            fake.emitRouteEvent(
                AudioRouteChangeEvent(
                    reasonRawValue: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
                    activePort: nil
                )
            )
        }
        #expect(change?.reason == .oldDeviceUnavailable)
        #expect(change?.activeInput == nil)
    }

    @Test func contractDebouncesRapidRouteChangesAndKeepsTheLatest() async {
        let usb = FakeAudioInputSessionPort.usbSnapshot(uid: "burst-usb", name: "USB")
        let bt = FakeAudioInputSessionPort.bluetoothSnapshot(uid: "burst-bt", name: "AirPods")
        let fake = FakeAudioInputSessionPort()
        let service = AppleAudioInputService(port: fake, routeDebounce: .milliseconds(120))
        let newDevice = AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue

        let collected = TestBox<[AudioRouteChange]>([])
        let consumer = Task {
            for await change in service.routeChanges() {
                collected.mutate { $0.append(change) }
            }
        }
        defer { consumer.cancel() }
        try? await Task.sleep(nanoseconds: 20_000_000)

        // Burst with no suspension between emits → all inside one debounce window.
        for _ in 0..<5 {
            fake.emitRouteEvent(AudioRouteChangeEvent(reasonRawValue: newDevice, activePort: usb))
        }
        fake.emitRouteEvent(AudioRouteChangeEvent(reasonRawValue: newDevice, activePort: bt))

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, collected.value.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        // Allow any wrongly un-coalesced extras to arrive before asserting.
        try? await Task.sleep(nanoseconds: 250_000_000)

        #expect(collected.value.isEmpty == false)       // a debounced burst is not dropped
        #expect(collected.value.count < 6)               // coalesced, not one-per-event
        #expect(collected.value.last?.activeInput?.id == "burst-bt")  // latest wins
    }

    @Test func contractRouteStreamKeepsMappingAfterAnActiveSelection() async throws {
        let usb = FakeAudioInputSessionPort.usbSnapshot(uid: "cap-usb")
        let fake = FakeAudioInputSessionPort(scriptedPorts: [usb], scriptedCurrentPort: usb)
        let service = AppleAudioInputService(port: fake, routeDebounce: .milliseconds(20))

        // Selection ≈ capture configured; a route change arriving *after* it is
        // still mapped and delivered (route stream independent of selection).
        try service.select(
            AudioInputDescriptor(
                id: usb.uid, kind: .wired, displayName: usb.portName, portType: usb.portTypeRawValue
            )
        )

        let change = await firstRouteChange(from: service) {
            fake.emitRouteEvent(
                AudioRouteChangeEvent(
                    reasonRawValue: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
                    activePort: nil
                )
            )
        }
        #expect(change?.reason == .oldDeviceUnavailable)
        #expect(change?.activeInput == nil)
    }

    @Test func contractRouteChangesCancellationTerminatesTheInjectedRawStream() async {
        let fake = FakeAudioInputSessionPort()
        let service = AppleAudioInputService(port: fake, routeDebounce: .milliseconds(20))
        let consumer = Task {
            for await _ in service.routeChanges() {}
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
        consumer.cancel()

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !fake.routeEventsStreamTerminated {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(fake.routeEventsStreamTerminated)
    }
}

/// Minimal lock-guarded box so a consuming `Task` and the test task can share a
/// collection without data races (Swift 6 `complete` concurrency).
final class TestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func mutate(_ transform: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        transform(&storage)
    }
}
