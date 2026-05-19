import Foundation

/// User-facing grouping of physical input routes.
///
/// The picker exposes only these three buckets, not the raw `AVAudioSession.Port`
/// set, per `docs/eval/audio-input-matrix.md` ("Settings UI mapping"). `.other`
/// keeps unforeseen routes (CarPlay, AirPlay) representable rather than silently
/// dropped.
enum AudioInputKind: String, CaseIterable, Sendable, Codable {
    /// Built-in iPhone microphone — demo-only path (`AVAudioSession.Port.builtInMic`).
    case builtInMicrophone

    /// Wired headset or class-compliant USB-C interface — primary supported path
    /// (`AVAudioSession.Port.headsetMic`, `.usbAudio`, `.lineIn`).
    case wired

    /// Bluetooth / AirPods — best-effort, codec-latency-bound
    /// (`AVAudioSession.Port.bluetoothHFP`, `.bluetoothLE`).
    case bluetooth

    /// Any other route (e.g. CarPlay), kept selectable but not characterized.
    case other
}

/// A selectable input route, derived from one `AVAudioSessionPortDescription`.
///
/// `id` is the port `uid` so a selection survives relaunch and identifies the same
/// physical device per `prd-ios-mvp.md` F5 ("saved per device"). `portType` carries
/// the raw `AVAudioSession.Port` value so the concrete service can re-resolve the
/// descriptor without leaking AVFoundation into Core. `Codable` so the audio-source
/// settings store (W3a) round-trips it like `PrivacySettings`.
struct AudioInputDescriptor: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let kind: AudioInputKind
    let displayName: String
    let portType: String

    init(id: String, kind: AudioInputKind, displayName: String, portType: String) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.portType = portType
    }
}

/// A single metering sample for the Settings "Test level" meter (PRD F5).
///
/// Powers are dBFS (`AVAudioPlayerNode`/tap convention, ≤ 0). `normalized` maps the
/// usable range onto `0...1` for a bar without callers re-deriving the curve. The
/// low-signal heuristic from `audio-input-matrix.md` ("SNR < 10 dB → warn") is a
/// view-model decision; this type stays pure data.
struct AudioInputLevel: Equatable, Sendable {
    let averagePowerDB: Float
    let peakPowerDB: Float

    init(averagePowerDB: Float, peakPowerDB: Float) {
        self.averagePowerDB = averagePowerDB
        self.peakPowerDB = peakPowerDB
    }

    /// `averagePowerDB` clamped from a −60 dBFS floor onto `0...1`.
    var normalized: Float {
        let floorDB: Float = -60
        guard averagePowerDB > floorDB else { return 0 }
        guard averagePowerDB < 0 else { return 1 }
        return (averagePowerDB - floorDB) / -floorDB
    }
}

/// Why the active audio route changed.
///
/// Mirrors the `AVAudioSession.RouteChangeReason` cases relevant to a receive-only
/// input picker (verified against Apple DocC
/// `documentation/avfaudio/avaudiosession/routechangenotification`). Drives live
/// refresh of the picker when a USB-C/wired device is plugged or pulled.
enum AudioRouteChangeReason: String, Sendable {
    case newDeviceAvailable
    case oldDeviceUnavailable
    case categoryChange
    case override
    case configurationChange
    case unknown
}

/// A route-change event delivered to the picker view model.
struct AudioRouteChange: Equatable, Sendable {
    let reason: AudioRouteChangeReason
    let activeInput: AudioInputDescriptor?

    init(reason: AudioRouteChangeReason, activeInput: AudioInputDescriptor?) {
        self.reason = reason
        self.activeInput = activeInput
    }
}

/// Typed failures from the audio-input boundary.
///
/// No case represents user error; every case is a real device/session condition.
/// Errors propagate to one boundary (the picker view model, W3a), which logs and
/// renders a non-blocking message — capture is never silently disabled.
enum AudioInputServiceError: Error, Equatable, Sendable {
    /// `AVAudioSession` could not be configured (category/mode set failed).
    case audioSessionUnavailable(String)

    /// `AVAudioSession.availableInputs` was `nil` or empty for the active category.
    case noInputsAvailable

    /// `setPreferredInput(_:)` rejected the descriptor (not in `availableInputs`).
    case inputNotSelectable(AudioInputDescriptor)

    /// The session could not be activated to apply the selection.
    case activationFailed(String)

    /// The metering tap could not be installed for the "Test level" meter.
    case meteringUnavailable(String)
}

/// Audio-input enumeration, selection, live metering, and route observation for
/// the Settings audio-source picker (PRD `docs/product/prd-ios-mvp.md` F5;
/// `docs/eval/audio-input-matrix.md`).
///
/// Built on `AVAudioSession.availableInputs` /
/// `setPreferredInput(_:)` / `routeChangeNotification` (verified against Apple
/// DocC `documentation/avfaudio/avaudiosession/{availableinputs,setpreferredinput(_:),routechangenotification}`).
/// The recognition session keeps `AVAudioSession.Mode.measurement` (already used at
/// `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:78`): it disables
/// system AGC/EQ for faithful ATC audio, where `.voiceChat` would apply two-way
/// VoIP processing that mangles receive-only radio.
///
/// `Sendable`: `AVAudioSession` work is off the main actor; the route-change
/// notification is posted on a secondary thread (Apple DocC), so the conforming
/// type hops to the picker view model's actor. Streams carry `Sendable` elements.
protocol AudioInputService: Sendable {
    /// Enumerates currently available input routes.
    ///
    /// - Throws: ``AudioInputServiceError/noInputsAvailable`` rather than returning
    ///   an empty/optional collection, so the absence is handled explicitly.
    func availableInputs() throws(AudioInputServiceError) -> [AudioInputDescriptor]

    /// The route currently feeding capture, or `nil` before the session is
    /// configured. `nil` is a legitimate pre-configuration *state*, not a failure.
    func currentInput() -> AudioInputDescriptor?

    /// Makes `input` the preferred capture route, persisting per device upstream.
    ///
    /// - Throws: ``AudioInputServiceError/inputNotSelectable(_:)`` if the route is
    ///   no longer available, ``AudioInputServiceError/activationFailed(_:)`` if
    ///   the session will not activate.
    func select(_ input: AudioInputDescriptor) throws(AudioInputServiceError)

    /// A stream of metering samples for the "Test level" meter while the Settings
    /// audio page is visible. The stream finishes when metering stops.
    ///
    /// `AsyncThrowingStream<_, Error>` matches the existing capture/ASR seam
    /// (`AudioCaptureService`, `SpeechRecognitionService`); the failure surfaces
    /// ``AudioInputServiceError/meteringUnavailable(_:)``.
    func levels() -> AsyncThrowingStream<AudioInputLevel, Error>

    /// A stream of route changes so the picker refreshes when a wired/USB-C device
    /// is plugged or pulled. Route changes are events, not failures — non-throwing.
    func routeChanges() -> AsyncStream<AudioRouteChange>
}

/// An AVFoundation-free snapshot of one input port.
///
/// The pure-Core projection of the three `AVAudioSessionPortDescription`
/// fields the audio adapter's mapping logic consumes — `uid`, `portName`,
/// `portType.rawValue` (verified against Apple DocC
/// `documentation/avfaudio/avaudiosessionportdescription`; no new Apple symbol
/// is introduced by this seam — it carries those values as plain `String`).
/// It exists so ``AudioInputDescriptor`` / ``AudioRouteChangeReason``
/// derivation can be exercised on the host without `AVAudioSession`, which has
/// no public initializer and is not designed for subclass override.
struct AudioPortSnapshot: Equatable, Sendable {
    let uid: String
    let portName: String
    let portTypeRawValue: String

    init(uid: String, portName: String, portTypeRawValue: String) {
        self.uid = uid
        self.portName = portName
        self.portTypeRawValue = portTypeRawValue
    }
}

/// One raw route-change event, before Core maps it onto ``AudioRouteChange``.
///
/// `reasonRawValue` is the unmapped `AVAudioSession.RouteChangeReason` raw
/// value taken from the notification `userInfo` key
/// `AVAudioSessionRouteChangeReasonKey` (verified against Apple DocC
/// `documentation/avfaudio/avaudiosession/routechangenotification`), or `nil`
/// when the key is absent. Mapping it onto ``AudioRouteChangeReason`` and
/// coalescing rapid changes are pure-Core, host-testable steps the adapter
/// performs — deliberately not this seam's responsibility.
struct AudioRouteChangeEvent: Equatable, Sendable {
    let reasonRawValue: UInt?
    let activePort: AudioPortSnapshot?

    init(reasonRawValue: UInt?, activePort: AudioPortSnapshot?) {
        self.reasonRawValue = reasonRawValue
        self.activePort = activePort
    }
}

/// Pure-Core dependency seam beneath ``AudioInputService``'s AVFoundation
/// adapter.
///
/// ## Why this exists
/// `AppleAudioInputService` / `AudioRouteChangeObserver` were built reading
/// `AVAudioSession.sharedInstance()` directly. `AVAudioSession` has no public
/// initializer and is not override-designed, so the adapter's enumeration,
/// uid-match selection, route-reason mapping, debounce, and stream-cancellation
/// paths are **not host-unit-testable as built** — they are device-only. The
/// W3 audio tester escalated this as a CRITICAL testability defect
/// (`docs/handoff.md` "W3 audio tester block" escalation #1; root cause: the
/// frozen audio protocol never exposed a fakeable seam — an architect defect,
/// remediated here additively, the existing ``AudioInputService`` unchanged).
///
/// This protocol is that seam. The real `AVAudioSession`-backed conformer
/// (W3a, imports AVFoundation, itself device-only) and a host fake both
/// conform, so the adapter becomes a pure orchestrator whose decisions are
/// unit-testable. It deliberately exposes **only Core value types** — no
/// `AVFoundation` import in Core, per
/// `docs/architecture-mvp-slice-2026-05-19.md` "Test seams".
///
/// ## Adapter contract (W3a adoption guidance — orchestration stays host-testable)
/// - `availableInputs()` → ``configureForMeasurement()`` then
///   ``availablePorts()``, mapping each snapshot to ``AudioInputDescriptor``;
///   throw ``AudioInputServiceError/noInputsAvailable`` on an empty result —
///   the empty-vs-error decision is the host-tested step.
/// - `select(_:)` → ``configureForMeasurement()``, ``activate()``, verify the
///   descriptor's `id` is present in ``availablePorts()`` and throw
///   ``AudioInputServiceError/inputNotSelectable(_:)`` from the adapter when it
///   is not (the descriptor-bearing error stays adapter-owned and host-tested),
///   then delegate to ``setPreferredInput(portUID:)``.
/// - `routeChanges()` → map each ``routeChangeEvents()`` element onto
///   ``AudioRouteChange`` (reason-code mapping plus rapid-change debounce live
///   here, in pure Core, host-tested — closes handoff escalation #3).
///
/// `Sendable` with an explicit `async` stream so isolation stays correct under
/// Swift 6.0 nonisolated-default and a future Swift 6.2
/// `defaultIsolation(MainActor.self)` migration alike.
protocol AudioInputSessionPort: Sendable {
    /// Puts the shared session into `.record` / `.measurement` for faithful
    /// receive-only capture (system AGC/EQ off, as the ASR engine uses).
    ///
    /// - Throws: ``AudioInputServiceError/audioSessionUnavailable(_:)`` — never
    ///   a silent no-op.
    func configureForMeasurement() throws(AudioInputServiceError)

    /// Activates the session so a preferred-input change takes effect.
    ///
    /// - Throws: ``AudioInputServiceError/activationFailed(_:)``.
    func activate() throws(AudioInputServiceError)

    /// Currently available input ports as AVFoundation-free snapshots. Returns
    /// `[]` (never `nil`) when none are available — the adapter decides whether
    /// `[]` is ``AudioInputServiceError/noInputsAvailable``.
    func availablePorts() -> [AudioPortSnapshot]

    /// The port currently feeding capture, or `nil` before the session is
    /// configured (a legitimate pre-configuration state, not a failure).
    func currentInputPort() -> AudioPortSnapshot?

    /// Makes the port identified by `portUID` the preferred capture route.
    ///
    /// The adapter performs the host-testable membership pre-check against
    /// ``availablePorts()`` and owns ``AudioInputServiceError/inputNotSelectable(_:)``;
    /// this call covers the residual session-level rejection.
    ///
    /// - Throws: ``AudioInputServiceError/activationFailed(_:)`` if the session
    ///   rejects the preferred-input change.
    func setPreferredInput(portUID: String) throws(AudioInputServiceError)

    /// Raw route-change events. Reason-code mapping and rapid-change debounce
    /// are performed by the adapter in pure Core, not here. Route changes are
    /// events, not failures — non-throwing.
    func routeChangeEvents() -> AsyncStream<AudioRouteChangeEvent>
}
