import Foundation

/// The three first-run cards, in order, from `prd-ios-mvp.md` §1.3 (lines 42-44).
///
/// Order is the presentation order; `allCases` is the script. Copy lives in the
/// view (W4a), not here — this is the state machine only.
enum FirstRunCard: String, CaseIterable, Sendable {
    /// "Receive-only — Dspeech does not transmit on the radio."
    case receiveOnly

    /// "Local by default — your audio stays on this iPhone."
    case localByDefault

    /// "Wire it for cockpit accuracy — built-in mic is for trying the app."
    case wireForAccuracy
}

/// Whether onboarding is showing, and which card.
///
/// A discriminated union so an illegal "completed but still on card 2" state is
/// unrepresentable (repo `CLAUDE.md` "make illegal states unrepresentable").
enum FirstRunState: Equatable, Sendable {
    case showing(FirstRunCard)
    case completed
}

/// Typed failure from persisting first-run completion.
///
/// Only one real failure exists: the backing store cannot record completion (e.g.
/// protected-data unavailable before first unlock). Reading state never fails — a
/// missing flag means "fresh install, show onboarding", the fail-safe default,
/// mirroring `UserDefaultsPrivacySettingsStorage.loadPrivacyMode()` returning
/// `.localOnly`.
enum FirstRunCoordinatorError: Error, Equatable, Sendable {
    case persistenceUnavailable(String)
}

/// Persistence of the one-bit "first run completed" flag.
///
/// Storage protocol mirrors the `PrivacySettingsStorage` template
/// (`Dspeech/Core/Settings/PrivacySettings.swift`): `Sendable`, injected, with a
/// `UserDefaults`-backed implementation supplied by W4a.
protocol FirstRunStateStore: Sendable {
    /// `true` once onboarding has been completed or skipped. A missing/unreadable
    /// flag returns `false` (show onboarding) — never throws.
    func hasCompletedFirstRun() -> Bool

    /// Records completion durably.
    ///
    /// - Throws: ``FirstRunCoordinatorError/persistenceUnavailable(_:)`` if the
    ///   store cannot write — surfaced to one boundary, never swallowed.
    func markFirstRunCompleted() throws(FirstRunCoordinatorError)
}

/// Drives the first-run card sequence (PRD §1.3): decide whether to show it,
/// advance through the three cards, and persist completion.
///
/// No account, no email, no analytics opt-in (ADR 0002; PRD §1.3 line 45).
/// `Sendable` so it can be injected into a `@MainActor @Observable` onboarding
/// view model the way `PrivacySettings` consumes `PrivacySettingsStorage`; the
/// concrete type (W4a) may itself be `@MainActor`. Method isolation is explicit,
/// so this is correct under Swift 6.0 nonisolated-default and a future Swift 6.2
/// main-actor-default migration alike.
protocol FirstRunCoordinator: Sendable {
    /// `.showing(.receiveOnly)` on a fresh install, `.completed` once the store
    /// records completion. Pure read — never throws.
    func currentState() -> FirstRunState

    /// Advances to the next card, or to `.completed` (persisting) after the last.
    ///
    /// - Returns: the new ``FirstRunState``.
    /// - Throws: ``FirstRunCoordinatorError/persistenceUnavailable(_:)`` if
    ///   completing the sequence cannot be persisted.
    func advance() throws(FirstRunCoordinatorError) -> FirstRunState

    /// Skips the remaining cards and records completion immediately.
    ///
    /// - Throws: ``FirstRunCoordinatorError/persistenceUnavailable(_:)``.
    func skip() throws(FirstRunCoordinatorError)
}
