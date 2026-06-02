import Foundation

@testable import Dspeech

final class FakeTranslationBackend: TranslationService, @unchecked Sendable {
  var statusToReturn: TranslationLanguageStatus = .installed
  var translateError: TranslationServiceError?
  var translationResult: String?
  var suspendUntilReleased = false

  private(set) var availabilityCallCount = 0
  private(set) var translateCallCount = 0
  private(set) var recordedInputs: [String] = []

  private let lock = NSLock()
  private var pending: [CheckedContinuation<Void, Never>] = []

  // why: lets a test hold a translate() call suspended off the main actor, then
  // supersede or reset it, so the view model's per-segment token guards are
  // actually exercised (a synchronous fake can never reproduce that race).
  func releaseAll() {
    lock.lock()
    let continuations = pending
    pending.removeAll()
    lock.unlock()
    for continuation in continuations { continuation.resume() }
  }

  func availability(
    translatingFrom source: Locale.Language,
    into target: Locale.Language
  ) async -> TranslationLanguageStatus {
    availabilityCallCount += 1
    return statusToReturn
  }

  func translate(
    _ text: String,
    from source: Locale.Language,
    into target: Locale.Language
  ) async throws(TranslationServiceError) -> String {
    translateCallCount += 1
    recordedInputs.append(text)
    if suspendUntilReleased {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        lock.lock()
        pending.append(continuation)
        lock.unlock()
      }
    }
    if let translateError {
      throw translateError
    }
    return translationResult ?? text
  }
}
