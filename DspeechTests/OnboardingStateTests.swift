import Foundation
import Testing

@testable import Dspeech

@MainActor
struct OnboardingStateTests {
  final class InMemoryStorage: OnboardingStateStorage, @unchecked Sendable {
    var stored: Bool?
    func loadHasCompletedOnboarding() -> Bool { stored ?? false }
    func saveHasCompletedOnboarding(_ completed: Bool) { stored = completed }
  }

  @Test func defaultsToNotCompleted() {
    let state = OnboardingState(storage: InMemoryStorage())
    #expect(state.hasCompletedOnboarding == false)
  }

  @Test func completePersistsAndIsIdempotent() {
    let storage = InMemoryStorage()
    let state = OnboardingState(storage: storage)

    state.complete()

    #expect(state.hasCompletedOnboarding)
    #expect(storage.stored == true)

    state.complete()
    #expect(storage.stored == true)
  }

  @Test func reflectsStoredCompletedOnInit() {
    let storage = InMemoryStorage()
    storage.stored = true
    let state = OnboardingState(storage: storage)
    #expect(state.hasCompletedOnboarding)
  }

  @Test func userDefaultsRoundTrip() {
    let suiteName = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let storage = UserDefaultsOnboardingStateStorage(defaults: defaults)
    #expect(storage.loadHasCompletedOnboarding() == false)

    storage.saveHasCompletedOnboarding(true)
    #expect(storage.loadHasCompletedOnboarding() == true)
  }

  @Test func userDefaultsParsesLaunchArgumentStrings() {
    let suiteName = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storage = UserDefaultsOnboardingStateStorage(defaults: defaults)

    defaults.set("true", forKey: UserDefaultsOnboardingStateStorage.completedKey)
    #expect(storage.loadHasCompletedOnboarding() == true)

    defaults.set("false", forKey: UserDefaultsOnboardingStateStorage.completedKey)
    #expect(storage.loadHasCompletedOnboarding() == false)
  }
}
