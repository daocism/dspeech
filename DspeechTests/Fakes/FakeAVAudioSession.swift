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
