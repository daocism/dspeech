@preconcurrency import AVFoundation
import Foundation

/// AVAudioSession-backed implementation of the frozen ``AudioInputService``
/// protocol (`Dspeech/Core/Audio/AudioInputServiceProtocol.swift`) for the
/// Settings audio-source picker (PRD `docs/product/prd-ios-mvp.md` F5).
///
/// ## API verification
/// Context7 MCP (`mcp__plugin_context7_context7__*`) is not mounted in the mac24
/// headless agent env, so — per the `CLAUDE.md` anti-hallucination "fetch current
/// docs" branch and exactly as the W1 architect recorded in `docs/handoff.md` —
/// every AVFoundation symbol below was verified against Apple's official DocC
/// JSON (`developer.apple.com/tutorials/data/documentation/…`) on 2026-05-19.
/// The DocC documentation path is the library-id equivalent:
///
/// - `documentation/avfaudio/avaudiosession/availableinputs` —
///   `var availableInputs: [AVAudioSessionPortDescription]?` (iOS 7).
/// - `documentation/avfaudio/avaudiosession/setpreferredinput(_:)` —
///   `func setPreferredInput(_:) throws` (iOS 7).
/// - `documentation/avfaudio/avaudiosession/currentroute` —
///   `var currentRoute: AVAudioSessionRouteDescription` (iOS 6).
/// - `documentation/avfaudio/avaudiosessionroutedescription/inputs` —
///   `var inputs: [AVAudioSessionPortDescription]` (iOS 6).
/// - `documentation/avfaudio/avaudiosessionportdescription` — `uid: String`,
///   `portName: String`, `portType: AVAudioSession.Port` (iOS 6).
/// - `documentation/avfaudio/avaudiosession/routechangenotification` —
///   `class let routeChangeNotification: NSNotification.Name` (iOS 6, posted on
///   a secondary thread).
/// - `documentation/avfaudio/avaudiosession/routechangereason` — cases
///   `newDeviceAvailable, oldDeviceUnavailable, categoryChange, override,
///   routeConfigurationChange, wakeFromSleep, noSuitableRouteForCategory,
///   unknown`; userInfo key `AVAudioSessionRouteChangeReasonKey`.
/// - `documentation/avfaudio/avaudioengine/inputnode` —
///   `var inputNode: AVAudioInputNode` (iOS 8).
/// - `documentation/avfaudio/avaudionode/installtap(onbus:buffersize:format:block:)`
///   — `block: @escaping AVAudioNodeTapBlock` (iOS 8).
/// - `documentation/avfaudio/avaudiopcmbuffer/floatchanneldata` —
///   `UnsafePointer<UnsafeMutablePointer<Float>>?` (iOS 8);
///   `documentation/avfaudio/avaudiopcmbuffer/framelength` —
///   `AVAudioFrameCount` (iOS 8).
/// - `documentation/foundation/notificationcenter/notifications(named:object:)`
///   — `@preconcurrency func notifications(named:object:) -> Notifications`
///   (iOS 15); called with `object` defaulted to `nil` so its
///   `(any AnyObject & Sendable)?` constraint never forces an AVAudioSession
///   Sendable conformance.
/// - `setCategory(_:mode:options:)` / `setActive(_:options:)` /
///   `AVAudioEngine.prepare()/start()/stop()/isRunning` /
///   `AVAudioNode.outputFormat(forBus:)/removeTap(onBus:)` are project-verified:
///   used by `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:76-156`,
///   which builds green under Swift 6 strict-concurrency `complete`.
///
/// `.measurement` mode is kept (same as the ASR engine,
/// `AppleSpeechLiveTranscriptionEngine.swift:78`): system AGC/EQ off for faithful
/// receive-only ATC audio; `.voiceChat` would apply two-way VoIP processing.
///
/// `Sendable`/threading: the frozen protocol is `: Sendable` (nonisolated, Swift
/// 6.0 nonisolated-by-default, 6.2-approachable). AVAudioSession work runs off the
/// main actor; the secondary-thread route notification is bridged through an
/// `AsyncStream`, so the picker view model consumes it on its own actor
/// (`docs/architecture-mvp-slice-2026-05-19.md` "Threading"). `@unchecked
/// Sendable` mirrors the `UserDefaultsPrivacySettingsStorage` precedent: the
/// type holds no mutable state — every AVAudioSession entry point reads the
/// process-wide shared session.
final class AppleAudioInputService: AudioInputService, @unchecked Sendable {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func availableInputs() throws(AudioInputServiceError) -> [AudioInputDescriptor] {
        try configureRecordSession()
        guard let inputs = session.availableInputs, !inputs.isEmpty else {
            throw AudioInputServiceError.noInputsAvailable
        }
        return inputs.map(Self.descriptor(from:))
    }

    func currentInput() -> AudioInputDescriptor? {
        guard let port = session.currentRoute.inputs.first else { return nil }
        return Self.descriptor(from: port)
    }

    func select(_ input: AudioInputDescriptor) throws(AudioInputServiceError) {
        try configureRecordSession()
        do {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw AudioInputServiceError.activationFailed(error.localizedDescription)
        }
        guard let inputs = session.availableInputs, !inputs.isEmpty else {
            throw AudioInputServiceError.noInputsAvailable
        }
        guard let match = inputs.first(where: { $0.uid == input.id }) else {
            throw AudioInputServiceError.inputNotSelectable(input)
        }
        do {
            try session.setPreferredInput(match)
        } catch {
            throw AudioInputServiceError.inputNotSelectable(input)
        }
    }

    func levels() -> AsyncThrowingStream<AudioInputLevel, Error> {
        AsyncThrowingStream<AudioInputLevel, Error> { continuation in
            let metering = MeteringSession()
            do {
                try metering.start { level in continuation.yield(level) }
            } catch {
                continuation.finish(throwing: error)
                return
            }
            continuation.onTermination = { _ in metering.stop() }
        }
    }

    func routeChanges() -> AsyncStream<AudioRouteChange> {
        AsyncStream<AudioRouteChange> { continuation in
            let session = self.session
            let task = Task {
                let notifications = NotificationCenter.default.notifications(
                    named: AVAudioSession.routeChangeNotification
                )
                for await notification in notifications {
                    let active = session.currentRoute.inputs.first.map(Self.descriptor(from:))
                    continuation.yield(
                        AudioRouteChange(
                            reason: Self.reason(from: notification),
                            activeInput: active
                        )
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func configureRecordSession() throws(AudioInputServiceError) {
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        } catch {
            throw AudioInputServiceError.audioSessionUnavailable(error.localizedDescription)
        }
    }

    static func descriptor(from port: AVAudioSessionPortDescription) -> AudioInputDescriptor {
        AudioInputDescriptor(
            id: port.uid,
            kind: kind(for: port.portType),
            displayName: port.portName,
            portType: port.portType.rawValue
        )
    }

    static func route(from port: AVAudioSessionPortDescription) -> AudioRoute {
        switch port.portType {
        case .builtInMic: return .builtInMic
        case .usbAudio: return .externalUSB(name: port.portName)
        case .headsetMic, .lineIn: return .wiredHeadset
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP:
            return .bluetooth(name: port.portName)
        default: return .other(name: port.portName)
        }
    }

    static func kind(for port: AVAudioSession.Port) -> AudioInputKind {
        switch port {
        case .builtInMic: return .builtInMicrophone
        case .headsetMic, .usbAudio, .lineIn: return .wired
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP: return .bluetooth
        default: return .other
        }
    }

    static func reason(from notification: Notification) -> AudioRouteChangeReason {
        guard
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else {
            return .unknown
        }
        switch reason {
        case .newDeviceAvailable: return .newDeviceAvailable
        case .oldDeviceUnavailable: return .oldDeviceUnavailable
        case .categoryChange: return .categoryChange
        case .override: return .override
        case .routeConfigurationChange: return .configurationChange
        case .unknown, .wakeFromSleep, .noSuitableRouteForCategory: return .unknown
        @unknown default: return .unknown
        }
    }

    /// RMS/peak dBFS of one capture buffer, floored at the −60 dBFS reference
    /// ``AudioInputLevel/normalized`` clamps from. Pure: no I/O, fully testable.
    static func level(from buffer: AVAudioPCMBuffer) -> AudioInputLevel? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return nil }

        var sumSquares: Float = 0
        var peak: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame]
                sumSquares += sample * sample
                let magnitude = abs(sample)
                if magnitude > peak { peak = magnitude }
            }
        }
        let rms = sqrt(sumSquares / Float(frameLength * channelCount))
        return AudioInputLevel(
            averagePowerDB: decibels(from: rms),
            peakPowerDB: decibels(from: peak)
        )
    }

    private static func decibels(from amplitude: Float) -> Float {
        let floorDB: Float = -60
        guard amplitude > 0 else { return floorDB }
        return max(20 * log10(amplitude), floorDB)
    }
}

/// One "Test level" metering run. Owns its own `AVAudioEngine` so it never edits
/// or depends on the ASR engine (dispatch: do not touch `LiveTranscriptionService`)
/// — only the process-wide `AVAudioSession` is shared, as the architecture
/// requires. `stop()` does not deactivate that shared session: the ASR engine
/// owns its activation lifecycle, so leaving it active avoids disrupting
/// concurrent capture (no `try?` swallow, no shared-state side effect).
///
/// `@unchecked Sendable`: `start` runs once on the stream-builder, `stop` once on
/// stream termination; the realtime tap block touches only the `@Sendable`
/// callback and its local buffer, never `engine`. Same `@preconcurrency
/// AVFoundation` capture pattern as `AppleSpeechLiveTranscriptionEngine.swift`,
/// which builds green under Swift 6 strict-concurrency `complete`.
private final class MeteringSession: @unchecked Sendable {
    private let engine = AVAudioEngine()

    func start(_ onLevel: @escaping @Sendable (AudioInputLevel) -> Void) throws(AudioInputServiceError) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        } catch {
            throw AudioInputServiceError.audioSessionUnavailable(error.localizedDescription)
        }
        do {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw AudioInputServiceError.activationFailed(error.localizedDescription)
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            if let level = AppleAudioInputService.level(from: buffer) {
                onLevel(level)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioInputServiceError.meteringUnavailable(error.localizedDescription)
        }
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }
}
