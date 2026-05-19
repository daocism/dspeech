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
