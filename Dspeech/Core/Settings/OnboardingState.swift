import Foundation
import Observation

protocol OnboardingStateStorage: Sendable {
  func loadHasCompletedOnboarding() -> Bool
  func saveHasCompletedOnboarding(_ completed: Bool)
}

struct UserDefaultsOnboardingStateStorage: OnboardingStateStorage, @unchecked Sendable {
  static let completedKey = "dspeech.onboarding.completed.v1"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func loadHasCompletedOnboarding() -> Bool {
    // why: an unset key resolves to false (show first-run), and a launch-argument
    // string ("true"/"false") used by XCUITests resolves via NSString boolValue —
    // both handled by UserDefaults.bool(forKey:), so no manual parsing is needed.
    defaults.bool(forKey: Self.completedKey)
  }

  func saveHasCompletedOnboarding(_ completed: Bool) {
    defaults.set(completed, forKey: Self.completedKey)
  }
}

protocol FirstSessionStateStorage: Sendable {
  func loadHasEverStarted() -> Bool
  func saveHasEverStarted(_ hasEverStarted: Bool)
}

// why: UserDefaults is safe for simple key reads/writes and this value type has no mutable
// shared state of its own.
struct UserDefaultsFirstSessionStateStorage: FirstSessionStateStorage, @unchecked Sendable {
  static let hasEverStartedKey = "dspeech.first-session.has-ever-started.v1"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func loadHasEverStarted() -> Bool {
    defaults.bool(forKey: Self.hasEverStartedKey)
  }

  func saveHasEverStarted(_ hasEverStarted: Bool) {
    defaults.set(hasEverStarted, forKey: Self.hasEverStartedKey)
  }
}

@MainActor
@Observable
final class OnboardingState {
  private let storage: OnboardingStateStorage
  private(set) var hasCompletedOnboarding: Bool

  init(storage: OnboardingStateStorage = UserDefaultsOnboardingStateStorage()) {
    self.storage = storage
    self.hasCompletedOnboarding = storage.loadHasCompletedOnboarding()
  }

  func complete() {
    guard !hasCompletedOnboarding else { return }
    hasCompletedOnboarding = true
    storage.saveHasCompletedOnboarding(true)
  }
}
