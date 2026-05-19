import Foundation
@testable import Dspeech

struct LanguagePair: Equatable, Sendable {
    let source: Locale.Language
    let target: Locale.Language
}

final class FakeTranslationBackend: TranslationService, @unchecked Sendable {
    var statusToReturn: TranslationLanguageStatus = .installed
    var translateError: TranslationServiceError?
    var translationResult: String?

    private(set) var availabilityCallCount = 0
    private(set) var translateCallCount = 0
    private(set) var recordedAvailabilityPairs: [LanguagePair] = []
    private(set) var recordedTranslatePairs: [LanguagePair] = []
    private(set) var recordedInputs: [String] = []

    func availability(
        translatingFrom source: Locale.Language,
        into target: Locale.Language
    ) async -> TranslationLanguageStatus {
        availabilityCallCount += 1
        recordedAvailabilityPairs.append(LanguagePair(source: source, target: target))
        return statusToReturn
    }

    func translate(
        _ text: String,
        from source: Locale.Language,
        into target: Locale.Language
    ) async throws(TranslationServiceError) -> String {
        translateCallCount += 1
        recordedTranslatePairs.append(LanguagePair(source: source, target: target))
        recordedInputs.append(text)
        if let translateError {
            throw translateError
        }
        return translationResult ?? text
    }
}

final class FakeTranslationPackBackend: TranslationLanguagePackPreparer, @unchecked Sendable {
    var prepareError: TranslationServiceError?

    private(set) var prepareCallCount = 0
    private(set) var recordedPreparePairs: [LanguagePair] = []

    func prepareLanguages(
        from source: Locale.Language,
        into target: Locale.Language
    ) async throws(TranslationServiceError) {
        prepareCallCount += 1
        recordedPreparePairs.append(LanguagePair(source: source, target: target))
        if let prepareError {
            throw prepareError
        }
    }
}
