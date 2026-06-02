import Foundation

@testable import Dspeech

final class FakeTranslationBackend: TranslationService, @unchecked Sendable {
  var statusToReturn: TranslationLanguageStatus = .installed
  var translateError: TranslationServiceError?
  var translationResult: String?

  private(set) var availabilityCallCount = 0
  private(set) var translateCallCount = 0
  private(set) var recordedInputs: [String] = []

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
    if let translateError {
      throw translateError
    }
    return translationResult ?? text
  }
}
