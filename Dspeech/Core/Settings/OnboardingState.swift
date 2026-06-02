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
