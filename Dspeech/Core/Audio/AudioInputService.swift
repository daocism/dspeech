@preconcurrency import AVFoundation
import Foundation

/// Orchestrator implementation of the frozen ``AudioInputService`` protocol
/// (`Dspeech/Core/Audio/AudioInputServiceProtocol.swift`) for the Settings
/// audio-source picker (PRD `docs/product/prd-ios-mvp.md` F5).
///
/// ## Why this is an orchestrator, not a direct `AVAudioSession` reader
/// The original W3 adapter read `AVAudioSession.sharedInstance()` directly, so
/// its enumeration / uid-match selection / route-reason mapping / debounce /
/// cancellation logic was device-only — the W3 audio tester escalated this as a
/// CRITICAL testability defect (`docs/handoff.md` "W3 audio tester block"
/// escalation #1; autopilot `fp=9ea645285fe6`). The architect remediated it by
/// adding the pure-Core ``AudioInputSessionPort`` seam (commit `5a6cf77`). This
/// type is now a **pure orchestrator over an injected `AudioInputSessionPort`**:
/// every decision (empty-vs-error, membership pre-check, port→descriptor /
/// port→route mapping, route-reason mapping, rapid-change debounce) operates on
/// Core value types and is host-unit-testable; the un-fakeable AVFoundation
/// shell is isolated in ``AVFoundationAudioInputSessionPort`` below. This also
/// closes the missing rapid-change debounce (autopilot `fp=9d12d5f9513b`,
/// handoff escalation #3), now in pure Core via ``debounced(_:interval:sleep:transform:)``.
///
/// ## API verification
/// Context7 MCP (`mcp__plugin_context7_context7__*`) is not mounted in the mac24
/// headless agent env (`ToolSearch` surfaces only WebSearch/WebFetch + Google
/// Drive — the same finding W1/W2/W3 and the architect recorded). Per the
/// `CLAUDE.md` anti-hallucination "fetch current docs" branch, every AVFoundation
/// symbol below was verified against Apple's official DocC JSON
/// (`developer.apple.com/tutorials/data/documentation/…`) on 2026-05-19; the DocC
/// documentation path is the library-id equivalent. This refactor introduces
/// **zero new Apple symbols** — every call is relocated from the d94891c-green
/// adapter into ``AVFoundationAudioInputSessionPort``; the only added symbolic
/// uses are `AVAudioSession.Port.<case>.rawValue` and
/// `AVAudioSession.RouteChangeReason(rawValue:)` (compiler-resolved references,
/// not string literals — nothing to hallucinate), the latter already present in
/// the original adapter.
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
/// - `documentation/avfaudio/avaudiosession/port` — `builtInMic`, `headsetMic`,
///   `usbAudio`, `lineIn`, `bluetoothHFP`, `bluetoothLE`, `bluetoothA2DP`
///   (RawRepresentable by `String`; `.rawValue` referenced symbolically).
/// - `documentation/avfaudio/avaudiosession/setcategory(_:mode:options:)` —
///   `func setCategory(_:mode:options:) throws` (iOS 10).
/// - `documentation/avfaudio/avaudiosession/setactive(_:options:)` —
///   `func setActive(_:options:) throws` (iOS 6).
/// - `documentation/avfaudio/avaudiosession/routechangenotification` —
///   `class let routeChangeNotification: NSNotification.Name` (iOS 6, posted on
///   a secondary thread; the `AsyncStream` bridges it to the consumer's actor).
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
///   (iOS 15); called with `object` defaulted to `nil`.
///
/// `.measurement` mode is kept (same as the ASR engine,
/// `AppleSpeechLiveTranscriptionEngine.swift:78`): system AGC/EQ off for faithful
/// receive-only ATC audio; `.voiceChat` would apply two-way VoIP processing. The
/// process-wide `AVAudioSession.sharedInstance()` is shared with the ASR engine;
/// the session is never deactivated here (ASR owns its activation lifecycle).
///
/// `@unchecked Sendable` mirrors the `UserDefaultsPrivacySettingsStorage`
/// precedent: the injected port is `Sendable`; the debounce closure is
/// `@Sendable`; no mutable state is held.
final class AppleAudioInputService: AudioInputService, @unchecked Sendable {
    /// Production trailing-debounce window for rapid route bursts (a USB-C plug
    /// fires `oldDeviceUnavailable`→`newDeviceAvailable`→`routeConfigurationChange`
    /// in quick succession; coalescing them prevents picker re-list thrash).
    static let defaultRouteDebounce: Duration = .milliseconds(300)

    /// Production time source. Injected so the debounce is deterministic in host
    /// tests (`@common/testing.md`: never real time — inject it).
    static let defaultSleep: @Sendable (Duration) async -> Void = { duration in
        try? await Task.sleep(for: duration)
    }

    private let port: any AudioInputSessionPort
    private let routeDebounce: Duration
    private let sleep: @Sendable (Duration) async -> Void

    init(
        port: any AudioInputSessionPort = AVFoundationAudioInputSessionPort(),
        routeDebounce: Duration = AppleAudioInputService.defaultRouteDebounce,
        sleep: @escaping @Sendable (Duration) async -> Void = AppleAudioInputService.defaultSleep
    ) {
        self.port = port
        self.routeDebounce = routeDebounce
        self.sleep = sleep
    }

    func availableInputs() throws(AudioInputServiceError) -> [AudioInputDescriptor] {
        try port.configureForMeasurement()
        let snapshots = port.availablePorts()
        guard !snapshots.isEmpty else {
            throw AudioInputServiceError.noInputsAvailable
        }
        return snapshots.map(Self.descriptor(from:))
    }

    func currentInput() -> AudioInputDescriptor? {
        port.currentInputPort().map(Self.descriptor(from:))
    }

    func select(_ input: AudioInputDescriptor) throws(AudioInputServiceError) {
        try port.configureForMeasurement()
        try port.activate()
        guard port.availablePorts().contains(where: { $0.uid == input.id }) else {
            throw AudioInputServiceError.inputNotSelectable(input)
        }
        try port.setPreferredInput(portUID: input.id)
    }

    func levels() -> AsyncThrowingStream<AudioInputLevel, Error> {
        AsyncThrowingStream<AudioInputLevel, Error> { continuation in
            let metering = MeteringSession()
            do {
                try port.configureForMeasurement()
                try port.activate()
                try metering.start { level in continuation.yield(level) }
            } catch {
                continuation.finish(throwing: error)
                return
            }
            continuation.onTermination = { _ in metering.stop() }
        }
    }

    func routeChanges() -> AsyncStream<AudioRouteChange> {
        Self.debounced(
            port.routeChangeEvents(),
            interval: routeDebounce,
            sleep: sleep
        ) { Self.mapped($0) }
    }

    // MARK: - Pure-Core mapping (host-testable: Core types in, Core types out)

    static func descriptor(from snapshot: AudioPortSnapshot) -> AudioInputDescriptor {
        AudioInputDescriptor(
            id: snapshot.uid,
            kind: kind(forPortType: snapshot.portTypeRawValue),
            displayName: snapshot.portName,
            portType: snapshot.portTypeRawValue
        )
    }

    static func route(from snapshot: AudioPortSnapshot) -> AudioRoute {
        let raw = snapshot.portTypeRawValue
        if raw == AVAudioSession.Port.builtInMic.rawValue {
            return .builtInMic
        }
        if raw == AVAudioSession.Port.usbAudio.rawValue {
            return .externalUSB(name: snapshot.portName)
        }
        if raw == AVAudioSession.Port.headsetMic.rawValue
            || raw == AVAudioSession.Port.lineIn.rawValue {
            return .wiredHeadset
        }
        if raw == AVAudioSession.Port.bluetoothHFP.rawValue
            || raw == AVAudioSession.Port.bluetoothLE.rawValue
            || raw == AVAudioSession.Port.bluetoothA2DP.rawValue {
            return .bluetooth(name: snapshot.portName)
        }
        return .other(name: snapshot.portName)
    }

    static func kind(forPortType raw: String) -> AudioInputKind {
        if raw == AVAudioSession.Port.builtInMic.rawValue {
            return .builtInMicrophone
        }
        if raw == AVAudioSession.Port.headsetMic.rawValue
            || raw == AVAudioSession.Port.usbAudio.rawValue
            || raw == AVAudioSession.Port.lineIn.rawValue {
            return .wired
        }
        if raw == AVAudioSession.Port.bluetoothHFP.rawValue
            || raw == AVAudioSession.Port.bluetoothLE.rawValue
            || raw == AVAudioSession.Port.bluetoothA2DP.rawValue {
            return .bluetooth
        }
        return .other
    }

    static func mapped(_ event: AudioRouteChangeEvent) -> AudioRouteChange {
        AudioRouteChange(
            reason: reason(forRawValue: event.reasonRawValue),
            activeInput: event.activePort.map(descriptor(from:))
        )
    }

    static func reason(forRawValue raw: UInt?) -> AudioRouteChangeReason {
        guard
            let raw,
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

    /// Trailing-edge debounce shared by ``routeChanges()`` and
    /// ``AudioRouteChangeObserver/routes()``: from a burst of upstream events,
    /// only the last survivor (after `interval` of quiet) is emitted, `transform`
    /// applied; a `nil` transform result drops that event. The same code runs in
    /// production and host tests — `sleep` is the only injected dependency
    /// (`@common/testing.md`: never real time, inject it), so W3b can drive a
    /// fake ``AudioInputSessionPort`` plus a controlled `sleep` and assert
    /// coalescing deterministically (closes handoff escalation #3).
    static func debounced<Element: Sendable, Mapped: Sendable>(
        _ upstream: AsyncStream<Element>,
        interval: Duration,
        sleep: @escaping @Sendable (Duration) async -> Void,
        transform: @escaping @Sendable (Element) -> Mapped?
    ) -> AsyncStream<Mapped> {
        AsyncStream<Mapped> { continuation in
            let pump = Task {
                var inFlight: Task<Void, Never>?
                for await element in upstream {
                    guard let value = transform(element) else { continue }
                    inFlight?.cancel()
                    inFlight = Task {
                        await sleep(interval)
                        // why: a superseded event was cancel()'d above so its
                        // isCancelled is true and it stays silent; the survivor
                        // is never cancelled and emits. A yield onto an already-
                        // terminated continuation (consumer cancelled) is a safe
                        // no-op, so no extra teardown of this detached task.
                        if !Task.isCancelled {
                            continuation.yield(value)
                        }
                    }
                }
                await inFlight?.value
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
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

/// The un-fakeable AVFoundation shell beneath ``AppleAudioInputService`` — the
/// real conformer of the architect-frozen ``AudioInputSessionPort`` seam
/// (`AudioInputServiceProtocol.swift`). It performs only the AVFoundation calls
/// (`AVAudioSession` has no public initializer and is not override-designed, so
/// this layer is intentionally device-only); all decision logic lives in the
/// host-testable orchestrator. Every symbol here is DocC-cited on
/// ``AppleAudioInputService`` and was proven green at `d94891c`.
///
/// `@unchecked Sendable`: holds no mutable state — every entry point reads the
/// process-wide `AVAudioSession.sharedInstance()` shared with the ASR engine.
final class AVFoundationAudioInputSessionPort: AudioInputSessionPort, @unchecked Sendable {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func configureForMeasurement() throws(AudioInputServiceError) {
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        } catch {
            throw AudioInputServiceError.audioSessionUnavailable(error.localizedDescription)
        }
    }

    func activate() throws(AudioInputServiceError) {
        do {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw AudioInputServiceError.activationFailed(error.localizedDescription)
        }
    }

    func availablePorts() -> [AudioPortSnapshot] {
        (session.availableInputs ?? []).map(Self.snapshot(from:))
    }

    func currentInputPort() -> AudioPortSnapshot? {
        session.currentRoute.inputs.first.map(Self.snapshot(from:))
    }

    func setPreferredInput(portUID: String) throws(AudioInputServiceError) {
        guard
            let match = session.availableInputs?.first(where: { $0.uid == portUID })
        else {
            throw AudioInputServiceError.activationFailed("preferred input \(portUID) no longer available")
        }
        do {
            try session.setPreferredInput(match)
        } catch {
            throw AudioInputServiceError.activationFailed(error.localizedDescription)
        }
    }

    func routeChangeEvents() -> AsyncStream<AudioRouteChangeEvent> {
        AsyncStream<AudioRouteChangeEvent> { continuation in
            let session = self.session
            let task = Task {
                let notifications = NotificationCenter.default.notifications(
                    named: AVAudioSession.routeChangeNotification
                )
                for await notification in notifications {
                    let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    let activePort = session.currentRoute.inputs.first.map(Self.snapshot(from:))
                    continuation.yield(
                        AudioRouteChangeEvent(reasonRawValue: reasonRaw, activePort: activePort)
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func snapshot(from port: AVAudioSessionPortDescription) -> AudioPortSnapshot {
        AudioPortSnapshot(
            uid: port.uid,
            portName: port.portName,
            portTypeRawValue: port.portType.rawValue
        )
    }
}

/// One "Test level" metering run. Owns its own `AVAudioEngine` so it never edits
/// or depends on the ASR engine (dispatch: do not touch `LiveTranscriptionService`)
/// — only the process-wide `AVAudioSession` is shared, and its category/activation
/// is configured by the injected ``AudioInputSessionPort`` before `start()`, so
/// this type is purely the engine-tap shell. `stop()` does not deactivate the
/// shared session: the ASR engine owns that lifecycle, so leaving it active
/// avoids disrupting concurrent capture (no `try?` swallow, no shared-state side
/// effect). The metering tap is inherently `AVAudioEngine`-bound (the frozen
/// ``AudioInputSessionPort`` deliberately scopes no metering method — extending
/// it would edit an architect-frozen signature), so this stays device-gated.
///
/// `@unchecked Sendable`: `start` runs once on the stream-builder, `stop` once on
/// stream termination; the realtime tap block touches only the `@Sendable`
/// callback and its local buffer, never `engine`. Same `@preconcurrency
/// AVFoundation` capture pattern as `AppleSpeechLiveTranscriptionEngine.swift`,
/// which builds green under Swift 6 strict-concurrency `complete`.
private final class MeteringSession: @unchecked Sendable {
    private let engine = AVAudioEngine()

    func start(_ onLevel: @escaping @Sendable (AudioInputLevel) -> Void) throws(AudioInputServiceError) {
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
