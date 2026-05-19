import Foundation

/// `UserDefaults`-backed persistence of the one-bit "first run completed" flag.
///
/// Mirrors the `UserDefaultsPrivacySettingsStorage` template
/// (`Dspeech/Core/Settings/PrivacySettings.swift`): a nonisolated
/// `@unchecked Sendable` value type so it satisfies the `Sendable`,
/// synchronous ``FirstRunStateStore`` requirements without main-actor isolation.
///
/// ``completedDefaultsKey`` is intentionally a stable, public-to-the-module
/// constant: the SwiftUI integrator (W5) gates onboarding presentation with
/// `@AppStorage(UserDefaultsFirstRunStateStore.completedDefaultsKey)` for
/// reactive hiding, while this store stays the single *writer* of the bit — one
/// source of truth, two readers.
struct UserDefaultsFirstRunStateStore: FirstRunStateStore, @unchecked Sendable {
    static let completedDefaultsKey = "hasCompletedFirstRun"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hasCompletedFirstRun() -> Bool {
        defaults.bool(forKey: Self.completedDefaultsKey)
    }

    func markFirstRunCompleted() throws(FirstRunCoordinatorError) {
        defaults.set(true, forKey: Self.completedDefaultsKey)
        guard defaults.bool(forKey: Self.completedDefaultsKey) else {
            throw .persistenceUnavailable(
                "UserDefaults did not retain \(Self.completedDefaultsKey)"
            )
        }
    }
}

/// Pure state machine over ``FirstRunCard/allCases`` (PRD §1.3): decide whether
/// onboarding shows, walk the three cards in order, persist completion.
///
/// `@unchecked Sendable` with an `NSLock` guarding the only mutable state (the
/// card cursor) — the concurrency-primitive exception to immutability, the same
/// shape as the `PrivacySettings` storage template but with a class because
/// progression must survive across `advance()` calls within an onboarding
/// session. `UserDefaults` is itself thread-safe, so store calls stay outside
/// the lock; the lock guards `cardIndex` only.
///
/// A missing/unreadable completion flag means "fresh install, show onboarding"
/// — the fail-safe default, matching `UserDefaultsPrivacySettingsStorage`
/// returning `.localOnly`. `currentState()` never throws; only persisting
/// completion can fail, surfaced as ``FirstRunCoordinatorError/persistenceUnavailable(_:)``.
final class DefaultFirstRunCoordinator: FirstRunCoordinator, @unchecked Sendable {
    private let store: any FirstRunStateStore
    private let cards = FirstRunCard.allCases
    private let lock = NSLock()
    private var cardIndex = 0

    init(store: any FirstRunStateStore = UserDefaultsFirstRunStateStore()) {
        self.store = store
    }

    func currentState() -> FirstRunState {
        if store.hasCompletedFirstRun() { return .completed }
        lock.lock()
        let index = min(cardIndex, cards.count - 1)
        lock.unlock()
        return .showing(cards[index])
    }

    func advance() throws(FirstRunCoordinatorError) -> FirstRunState {
        if store.hasCompletedFirstRun() { return .completed }

        lock.lock()
        let isLastCard = cardIndex + 1 >= cards.count
        if !isLastCard {
            cardIndex += 1
            let card = cards[cardIndex]
            lock.unlock()
            return .showing(card)
        }
        lock.unlock()

        try store.markFirstRunCompleted()
        return .completed
    }

    func skip() throws(FirstRunCoordinatorError) {
        if store.hasCompletedFirstRun() { return }
        try store.markFirstRunCompleted()
    }
}
