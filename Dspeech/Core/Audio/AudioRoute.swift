import Foundation

/// The physically active capture route, as a pure domain value.
///
/// Distinct from the frozen ``AudioInputDescriptor`` (the *selectable* list entry
/// for the picker) and ``AudioRouteChange`` (a picker event carrying a reason):
/// `AudioRoute` answers "what is feeding capture *right now*" for route-display
/// and route-observation. It carries no AVFoundation type so it stays trivially
/// testable (`docs/architecture-mvp-slice-2026-05-19.md` "Test seams": no Apple
/// import in Core domain types).
///
/// `externalUSB`/`bluetooth`/`other` carry the human-readable port name so the
/// UI can show "Behringer UMC202HD" rather than a bare bucket. `other` keeps
/// CarPlay/AirPlay representable instead of silently misclassifying them as a
/// built-in mic — the same rationale the frozen ``AudioInputKind/other`` states
/// (`Dspeech/Core/Audio/AudioInputServiceProtocol.swift:21-22`); the dispatch's
/// four-case list is widened by this one case to honor the "no silent failures"
/// rule rather than collapse unknown routes.
enum AudioRoute: Equatable, Sendable {
    /// Built-in iPhone microphone (Apple DocC `documentation/avfaudio/avaudiosession/port/builtinmic`).
    case builtInMic

    /// Wired headset or line-in (Apple DocC `…/port/headsetmic`, `…/port/linein`).
    case wiredHeadset

    /// Class-compliant USB-C audio interface — the primary supported ATC path
    /// (Apple DocC `…/port/usbaudio`).
    case externalUSB(name: String)

    /// Bluetooth / AirPods, codec-latency-bound (Apple DocC `…/port/bluetoothhfp`,
    /// `…/port/bluetoothle`, `…/port/bluetootha2dp`).
    case bluetooth(name: String)

    /// Any route not characterized above (CarPlay, AirPlay), kept representable.
    case other(name: String)

    /// Display string for route-status UI; bucket label when no device name.
    var displayName: String {
        switch self {
        case .builtInMic: return "Встроенный микрофон"
        case .wiredHeadset: return "Проводная гарнитура"
        case .externalUSB(let name): return name
        case .bluetooth(let name): return name
        case .other(let name): return name
        }
    }
}
