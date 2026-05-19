import Foundation
import Testing
@testable import Dspeech

/// Test double for the AVAudioSession-fronting DI seam the W3 audio
/// implementer (`Dspeech/Core/Audio/`) must expose so `AppleAudioInputService`
/// and `AudioRouteChangeObserver` are testable without a device or AVFAudio.
///
/// CONTRACT REQUESTED OF W3 IMPL (documented in `docs/handoff.md` "W3 audio
/// tester" block — these symbols are RED until the impl lands):
///
/// ```swift
/// // Dspeech/Core/Audio/AudioRoute.swift
/// enum AudioRoute: Equatable, Sendable {
///     case builtInMic
///     case wiredHeadset
///     case externalUSB(name: String)
///     case bluetooth(name: String)
/// }
///
/// // Dspeech/Core/Audio/AudioInputService.swift (or AudioRouteChangeObserver.swift)
/// // — pure Core seam, no AVFAudio leak; the real adapter and this fake both conform.
/// protocol AudioInputSessionPort: Sendable {
///     func availableInputs() throws(AudioInputServiceError) -> [AudioInputDescriptor]
///     func currentInput() -> AudioInputDescriptor?
///     func setPreferredInput(_ input: AudioInputDescriptor) throws(AudioInputServiceError)
///     func routeChanges() -> AsyncStream<AudioRoute>
/// }
///
/// final class AppleAudioInputService: AudioInputService {
///     init(session: AudioInputSessionPort)
/// }
///
/// final class AudioRouteChangeObserver: Sendable {
///     init(session: AudioInputSessionPort)
///     func routes() -> AsyncStream<AudioRoute>   // debounced; .builtInMic fallback when no input
/// }
/// ```
///
/// Policy split (so policy is testable, the seam stays thin):
/// - `availableInputs()` on the seam returns the raw list (may be empty) and only
///   throws ``AudioInputServiceError/audioSessionUnavailable(_:)`` when the
///   session itself is unusable (e.g. record permission denied). The empty →
///   ``AudioInputServiceError/noInputsAvailable`` and "descriptor not present" →
///   ``AudioInputServiceError/inputNotSelectable(_:)`` decisions belong to
///   `AppleAudioInputService` and are asserted in `AudioInputServiceTests`.
final class FakeAVAudioSession: AudioInputSessionPort, @unchecked Sendable {
    var scriptedInputs: [AudioInputDescriptor]
    var scriptedCurrentInput: AudioInputDescriptor?

    /// When set, `availableInputs()` rethrows this (record-permission-denied path).
    var availableInputsError: AudioInputServiceError?
    /// When set, `setPreferredInput(_:)` rethrows this (activation/route-apply failure).
    var setPreferredError: AudioInputServiceError?

    private(set) var availableInputsCallCount = 0
    private(set) var lastPreferredInput: AudioInputDescriptor?
    private(set) var routeChangesContinuationFinished = false

    private var routeContinuation: AsyncStream<AudioRoute>.Continuation?

    init(
        scriptedInputs: [AudioInputDescriptor] = [],
        scriptedCurrentInput: AudioInputDescriptor? = nil
    ) {
        self.scriptedInputs = scriptedInputs
        self.scriptedCurrentInput = scriptedCurrentInput
    }

    func availableInputs() throws(AudioInputServiceError) -> [AudioInputDescriptor] {
        availableInputsCallCount += 1
        if let availableInputsError {
            throw availableInputsError
        }
        return scriptedInputs
    }

    func currentInput() -> AudioInputDescriptor? {
        scriptedCurrentInput
    }

    func setPreferredInput(_ input: AudioInputDescriptor) throws(AudioInputServiceError) {
        if let setPreferredError {
            throw setPreferredError
        }
        lastPreferredInput = input
        scriptedCurrentInput = input
    }

    func routeChanges() -> AsyncStream<AudioRoute> {
        AsyncStream<AudioRoute> { continuation in
            self.routeContinuation = continuation
            continuation.onTermination = { @Sendable _ in
                self.routeChangesContinuationFinished = true
            }
        }
    }

    /// Simulate one `AVAudioSession.routeChangeNotification` delivering `route`.
    func pushRoute(_ route: AudioRoute) {
        routeContinuation?.yield(route)
    }

    /// Simulate the device going away (session ends the raw route stream).
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

    static func wiredHeadsetDescriptor() -> AudioInputDescriptor {
        AudioInputDescriptor(
            id: "wired-headset-uid",
            kind: .wired,
            displayName: "Headset Microphone",
            portType: "HeadsetMicrophone"
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
