import AVFoundation
import Foundation
@testable import Dspeech

/// Scriptable fake conforming to the **frozen `AudioInputService` protocol** —
/// the test seam the architecture mandates
/// (`docs/architecture-mvp-slice-2026-05-19.md` "Test seams": *"All three
/// protocols are trivially fakeable (no Apple import in Core): … fake
/// `AudioInputService` yielding scripted `availableInputs`,
/// `AsyncThrowingStream` levels, and `routeChanges`"*).
///
/// ## Why this is not a fake of `AVAudioSession`
/// The W3 tester dispatch asked for a *"protocol-fronted fake, injected via
/// DI"*. The W3 implementer instead hardwired `AVAudioSession.sharedInstance()`
/// into `AppleAudioInputService` / `AudioRouteChangeObserver`
/// (`init(session: AVAudioSession = .sharedInstance())`) and reads
/// `session.currentRoute.inputs` + `NotificationCenter` directly. `AVAudioSession`
/// has no public initializer and is not designed for subclass override, so the
/// concrete adapter's enumeration / selection / route-mapping / debounce /
/// cancellation paths are **not host-unit-testable as built** — they are
/// device-only, and the missing fakeable Core seam is escalated to the
/// tech-lead in `docs/handoff.md` (W3 audio tester block).
///
/// What *is* host-testable and worth pinning is the **frozen contract** every
/// conformer (including `AppleAudioInputService` on device) must honour. This
/// fake scripts that contract so `AudioInputServiceTests` can assert the
/// semantics the protocol DocC promises (error vs empty, `nil`-as-state, stream
/// cancellation) without pretending to exercise AVFoundation internals.
final class FakeAVAudioSession: AudioInputService, @unchecked Sendable {
    var scriptedInputs: [AudioInputDescriptor]
    var scriptedCurrentInput: AudioInputDescriptor?
    var availableInputsError: AudioInputServiceError?
    var selectError: AudioInputServiceError?

    private(set) var selectedInput: AudioInputDescriptor?

    private var levelsContinuation: AsyncThrowingStream<AudioInputLevel, Error>.Continuation?
    private var routeContinuation: AsyncStream<AudioRouteChange>.Continuation?
    private(set) var levelsStreamTerminated = false
    private(set) var routeStreamTerminated = false

    init(
        scriptedInputs: [AudioInputDescriptor] = [],
        scriptedCurrentInput: AudioInputDescriptor? = nil
    ) {
        self.scriptedInputs = scriptedInputs
        self.scriptedCurrentInput = scriptedCurrentInput
    }

    func availableInputs() throws(AudioInputServiceError) -> [AudioInputDescriptor] {
        if let availableInputsError {
            throw availableInputsError
        }
        guard !scriptedInputs.isEmpty else {
            throw AudioInputServiceError.noInputsAvailable
        }
        return scriptedInputs
    }

    func currentInput() -> AudioInputDescriptor? {
        scriptedCurrentInput
    }

    func select(_ input: AudioInputDescriptor) throws(AudioInputServiceError) {
        if let selectError {
            throw selectError
        }
        guard scriptedInputs.contains(input) else {
            throw AudioInputServiceError.inputNotSelectable(input)
        }
        selectedInput = input
        scriptedCurrentInput = input
    }

    func levels() -> AsyncThrowingStream<AudioInputLevel, Error> {
        AsyncThrowingStream<AudioInputLevel, Error> { continuation in
            self.levelsContinuation = continuation
            continuation.onTermination = { @Sendable _ in
                self.levelsStreamTerminated = true
            }
        }
    }

    func routeChanges() -> AsyncStream<AudioRouteChange> {
        AsyncStream<AudioRouteChange> { continuation in
            self.routeContinuation = continuation
            continuation.onTermination = { @Sendable _ in
                self.routeStreamTerminated = true
            }
        }
    }

    func emitLevel(_ level: AudioInputLevel) {
        levelsContinuation?.yield(level)
    }

    func emitRouteChange(_ change: AudioRouteChange) {
        routeContinuation?.yield(change)
    }

    func finishRouteChanges() {
        routeContinuation?.finish()
    }
}

extension FakeAVAudioSession {
    static func builtInMicDescriptor() -> AudioInputDescriptor {
        AudioInputDescriptor(
            id: "builtin-mic-uid",
            kind: .builtInMicrophone,
            displayName: "iPhone Microphone",
            portType: "MicrophoneBuiltIn"
        )
    }

    static func usbDescriptor(name: String = "USB-C Audio") -> AudioInputDescriptor {
        AudioInputDescriptor(
            id: "usb-\(name)-uid",
            kind: .wired,
            displayName: name,
            portType: "USBAudio"
        )
    }

    static func bluetoothDescriptor(name: String = "AirPods Pro") -> AudioInputDescriptor {
        AudioInputDescriptor(
            id: "bt-\(name)-uid",
            kind: .bluetooth,
            displayName: name,
            portType: "BluetoothHFP"
        )
    }
}

/// Scriptable host fake conforming to the **pure-Core `AudioInputSessionPort`
/// DI seam** the architect shipped (commit `5a6cf77`,
/// `Dspeech/Core/Audio/AudioInputServiceProtocol.swift:243`).
///
/// This is the *"protocol-fronted fake, injected via DI"* the W3 tester
/// dispatch asked for and the original `AppleAudioInputService` omitted by
/// hardwiring `AVAudioSession.sharedInstance()` (`docs/handoff.md` "W3 audio
/// tester block" escalation #1; arch doc "Audio adapter DI seam").
/// `AVAudioSession` has no public initializer and is not override-designed, so
/// the adapter's enumeration / uid-match selection / reason-code mapping /
/// rapid-change debounce / cancellation paths were device-only as built. With
/// the seam in place, the refactored adapter is a pure orchestrator over an
/// injected `AudioInputSessionPort`; this fake scripts that seam so
/// `AudioInputServiceTests` / `AudioRouteTests` pin the orchestration contract
/// on the host. The real `AVAudioSession`-backed conformer (the un-fakeable
/// shell, W3a) and on-device USB-C route validation stay device-only.
final class FakeAudioInputSessionPort: AudioInputSessionPort, @unchecked Sendable {
    var scriptedPorts: [AudioPortSnapshot]
    var scriptedCurrentPort: AudioPortSnapshot?
    var configureError: AudioInputServiceError?
    var activateError: AudioInputServiceError?
    var preferredInputError: AudioInputServiceError?

    private(set) var configureCallCount = 0
    private(set) var activateCallCount = 0
    private(set) var preferredInputCallCount = 0
    private(set) var preferredInputUID: String?

    private let lock = NSLock()
    private var routeContinuation: AsyncStream<AudioRouteChangeEvent>.Continuation?
    private var _routeEventsStreamTerminated = false

    init(
        scriptedPorts: [AudioPortSnapshot] = [],
        scriptedCurrentPort: AudioPortSnapshot? = nil
    ) {
        self.scriptedPorts = scriptedPorts
        self.scriptedCurrentPort = scriptedCurrentPort
    }

    /// `true` once the consumer cancelled `routeChanges()` and the adapter
    /// tore down its subscription to this seam — proves no leaked Task.
    var routeEventsStreamTerminated: Bool {
        lock.lock(); defer { lock.unlock() }
        return _routeEventsStreamTerminated
    }

    func configureForMeasurement() throws(AudioInputServiceError) {
        configureCallCount += 1
        if let configureError { throw configureError }
    }

    func activate() throws(AudioInputServiceError) {
        activateCallCount += 1
        if let activateError { throw activateError }
    }

    func availablePorts() -> [AudioPortSnapshot] { scriptedPorts }

    func currentInputPort() -> AudioPortSnapshot? { scriptedCurrentPort }

    func setPreferredInput(portUID: String) throws(AudioInputServiceError) {
        preferredInputCallCount += 1
        preferredInputUID = portUID
        if let preferredInputError { throw preferredInputError }
    }

    func routeChangeEvents() -> AsyncStream<AudioRouteChangeEvent> {
        AsyncStream<AudioRouteChangeEvent> { continuation in
            self.lock.lock()
            self.routeContinuation = continuation
            self.lock.unlock()
            continuation.onTermination = { @Sendable _ in
                self.lock.lock()
                self._routeEventsStreamTerminated = true
                self.lock.unlock()
            }
        }
    }

    func emitRouteEvent(_ event: AudioRouteChangeEvent) {
        lock.lock()
        let continuation = routeContinuation
        lock.unlock()
        continuation?.yield(event)
    }

    func finishRouteEvents() {
        lock.lock()
        let continuation = routeContinuation
        lock.unlock()
        continuation?.finish()
    }
}

extension FakeAudioInputSessionPort {
    /// Port snapshots whose `portTypeRawValue` is read from the real
    /// `AVAudioSession.Port` constants the shipped adapter maps
    /// (`AppleAudioInputService.kind(for:)`,
    /// `Dspeech/Core/Audio/AudioInputService.swift:167`) — never a guessed
    /// literal. The raw→`AudioInputKind` mapping must agree with AVFoundation's
    /// *actual* strings, so the fixture sources them from Apple rather than
    /// asserting the mapping against a possibly-wrong remembered constant
    /// (CLAUDE.md anti-hallucination). `unmappedSnapshot` deliberately uses a
    /// non-Apple string to pin the `default → .other` branch.
    static func builtInMicSnapshot(uid: String = "builtin-mic-uid") -> AudioPortSnapshot {
        AudioPortSnapshot(
            uid: uid,
            portName: "iPhone Microphone",
            portTypeRawValue: AVAudioSession.Port.builtInMic.rawValue
        )
    }

    static func usbSnapshot(uid: String = "usb-c-uid", name: String = "USB-C Audio") -> AudioPortSnapshot {
        AudioPortSnapshot(
            uid: uid,
            portName: name,
            portTypeRawValue: AVAudioSession.Port.usbAudio.rawValue
        )
    }

    static func headsetSnapshot(uid: String = "headset-uid", name: String = "Wired Headset") -> AudioPortSnapshot {
        AudioPortSnapshot(
            uid: uid,
            portName: name,
            portTypeRawValue: AVAudioSession.Port.headsetMic.rawValue
        )
    }

    static func bluetoothSnapshot(uid: String = "bt-uid", name: String = "AirPods Pro") -> AudioPortSnapshot {
        AudioPortSnapshot(
            uid: uid,
            portName: name,
            portTypeRawValue: AVAudioSession.Port.bluetoothHFP.rawValue
        )
    }

    static func unmappedSnapshot(uid: String = "unmapped-uid", name: String = "CarPlay") -> AudioPortSnapshot {
        AudioPortSnapshot(
            uid: uid,
            portName: name,
            portTypeRawValue: "com.dspeech.test.UnmappedPortType"
        )
    }
}
