import Foundation
import Testing
@testable import Dspeech

struct FirstRunCoordinatorTests {
    /// In-memory backing for `FirstRunStateStore`, mirroring the
    /// `PrivacySettingsTests.InMemoryStorage` template so the coordinator's
    /// state machine can be exercised without `UserDefaults`.
    final class InMemoryStore: FirstRunStateStore, @unchecked Sendable {
        var completed: Bool = false
        var shouldFailToWrite: Bool = false
        private(set) var writeCount: Int = 0

        func hasCompletedFirstRun() -> Bool { completed }

        func markFirstRunCompleted() throws(FirstRunCoordinatorError) {
            writeCount += 1
            if shouldFailToWrite {
                throw .persistenceUnavailable("forced for test")
            }
            completed = true
        }
    }

    // MARK: initial state

    @Test func freshStoreShowsReceiveOnlyCard() {
        let store = InMemoryStore()
        let coordinator = DefaultFirstRunCoordinator(store: store)

        #expect(coordinator.currentState() == .showing(.receiveOnly))
    }

    @Test func storeWithCompletionFlagReportsCompleted() {
        let store = InMemoryStore()
        store.completed = true
        let coordinator = DefaultFirstRunCoordinator(store: store)

        #expect(coordinator.currentState() == .completed)
    }

    // MARK: progression — initial → permission → language → done

    @Test func advanceWalksCardsInDeclaredOrder() throws {
        let store = InMemoryStore()
        let coordinator = DefaultFirstRunCoordinator(store: store)

        #expect(coordinator.currentState() == .showing(.receiveOnly))

        let secondState = try coordinator.advance()
        #expect(secondState == .showing(.localByDefault))
        #expect(coordinator.currentState() == .showing(.localByDefault))

        let thirdState = try coordinator.advance()
        #expect(thirdState == .showing(.wireForAccuracy))
        #expect(coordinator.currentState() == .showing(.wireForAccuracy))

        let completed = try coordinator.advance()
        #expect(completed == .completed)
        #expect(coordinator.currentState() == .completed)
        #expect(store.completed)
        #expect(store.writeCount == 1)
    }

    @Test func advanceAfterCompletionStaysCompleted() throws {
        let store = InMemoryStore()
        let coordinator = DefaultFirstRunCoordinator(store: store)

        _ = try coordinator.advance()
        _ = try coordinator.advance()
        _ = try coordinator.advance()
        #expect(coordinator.currentState() == .completed)

        let stillCompleted = try coordinator.advance()
        #expect(stillCompleted == .completed)
        #expect(store.writeCount == 1, "completion bit must be persisted exactly once")
    }

    // MARK: skip — early bail-out short-circuits to .completed

    @Test func skipFromFirstCardPersistsAndJumpsToCompleted() throws {
        let store = InMemoryStore()
        let coordinator = DefaultFirstRunCoordinator(store: store)

        try coordinator.skip()

        #expect(coordinator.currentState() == .completed)
        #expect(store.completed)
        #expect(store.writeCount == 1)
    }

    @Test func skipFromMiddleCardJumpsStraightToCompleted() throws {
        let store = InMemoryStore()
        let coordinator = DefaultFirstRunCoordinator(store: store)
        _ = try coordinator.advance()

        #expect(coordinator.currentState() == .showing(.localByDefault))

        try coordinator.skip()

        #expect(coordinator.currentState() == .completed)
        #expect(store.writeCount == 1)
    }

    @Test func skipOnAlreadyCompletedStoreIsNoOp() throws {
        let store = InMemoryStore()
        store.completed = true
        let coordinator = DefaultFirstRunCoordinator(store: store)

        try coordinator.skip()

        #expect(coordinator.currentState() == .completed)
        #expect(store.writeCount == 0, "skip on completed store must not re-write")
    }

    // MARK: persistence-failure surfaces

    @Test func persistenceFailureOnFinalAdvanceSurfacesAsError() {
        let store = InMemoryStore()
        store.shouldFailToWrite = true
        let coordinator = DefaultFirstRunCoordinator(store: store)
        _ = try? coordinator.advance() // → .localByDefault
        _ = try? coordinator.advance() // → .wireForAccuracy

        do {
            _ = try coordinator.advance() // tries to mark completion, fails
            Issue.record("expected FirstRunCoordinatorError.persistenceUnavailable, returned a value")
        } catch {
            #expect(error == .persistenceUnavailable("forced for test"))
        }

        #expect(coordinator.currentState() == .showing(.wireForAccuracy),
                "state must stay on the last card when persistence fails")
        #expect(store.completed == false)
    }

    @Test func persistenceFailureOnSkipSurfacesAsError() {
        let store = InMemoryStore()
        store.shouldFailToWrite = true
        let coordinator = DefaultFirstRunCoordinator(store: store)

        do {
            try coordinator.skip()
            Issue.record("expected FirstRunCoordinatorError.persistenceUnavailable, skip returned normally")
        } catch {
            #expect(error == .persistenceUnavailable("forced for test"))
        }

        #expect(coordinator.currentState() == .showing(.receiveOnly))
        #expect(store.completed == false)
    }

    // MARK: card-order pin (PRD §1.3 lines 42-44)

    @Test func cardOrderMatchesPRDSequence() {
        #expect(FirstRunCard.allCases == [
            .receiveOnly,
            .localByDefault,
            .wireForAccuracy
        ])
    }

    // MARK: UserDefaults adapter round-trip

    @Test func userDefaultsStoreRoundTrip() throws {
        let suiteName = "dspeech.firstrun.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsFirstRunStateStore(defaults: defaults)
        #expect(store.hasCompletedFirstRun() == false, "missing key must read as not-completed")

        try store.markFirstRunCompleted()
        #expect(store.hasCompletedFirstRun())

        let reread = UserDefaultsFirstRunStateStore(defaults: defaults)
        #expect(reread.hasCompletedFirstRun(), "completion must survive a fresh store instance")
    }

    @Test func userDefaultsStoreKeyMatchesIntegratorContract() {
        // why: ContentView arms `@AppStorage("hasCompletedFirstRun")` from this
        // same key; renaming it without updating the integrator silently strands
        // every existing install on the onboarding cover.
        #expect(UserDefaultsFirstRunStateStore.completedDefaultsKey == "hasCompletedFirstRun")
    }
}
