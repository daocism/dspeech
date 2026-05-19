import Foundation
import Testing
@testable import Dspeech

@MainActor
struct TranslationLanguagePackManagerTests {
    private let en = Locale.Language(identifier: "en")
    private let ru = Locale.Language(identifier: "ru")
    private let uk = Locale.Language(identifier: "uk")

    private func makeSUT(_ backend: FakeTranslationPackBackend) -> TranslationLanguagePackManager {
        TranslationLanguagePackManager(backend: backend)
    }

    @Test func should_complete_when_backend_prepare_succeeds() async throws {
        let backend = FakeTranslationPackBackend()
        let sut = makeSUT(backend)

        try await sut.prepareLanguages(from: en, into: ru)

        #expect(backend.prepareCallCount == 1)
    }

    @Test func should_throw_sessionCancelled_when_user_dismisses_system_sheet() async {
        let backend = FakeTranslationPackBackend()
        backend.prepareError = .sessionCancelled
        let sut = makeSUT(backend)

        do {
            try await sut.prepareLanguages(from: en, into: ru)
            Issue.record("expected TranslationServiceError.sessionCancelled")
        } catch {
            #expect(error == .sessionCancelled)
        }
    }

    @Test func should_throw_languagePairingUnsupported_when_pair_cannot_be_installed() async {
        let backend = FakeTranslationPackBackend()
        backend.prepareError = .languagePairingUnsupported(source: en, target: uk)
        let sut = makeSUT(backend)

        do {
            try await sut.prepareLanguages(from: en, into: uk)
            Issue.record("expected TranslationServiceError.languagePairingUnsupported")
        } catch {
            #expect(error == .languagePairingUnsupported(source: en, target: uk))
        }
    }

    @Test func should_throw_engineFailure_when_backend_reports_internal_error() async {
        let backend = FakeTranslationPackBackend()
        backend.prepareError = .engineFailure("internalError")
        let sut = makeSUT(backend)

        do {
            try await sut.prepareLanguages(from: en, into: ru)
            Issue.record("expected TranslationServiceError.engineFailure")
        } catch {
            #expect(error == .engineFailure("internalError"))
        }
    }

    @Test func should_forward_exact_source_and_target_locales_to_backend() async throws {
        let backend = FakeTranslationPackBackend()
        let sut = makeSUT(backend)
        let source = Locale.Language(identifier: "en-GB")
        let target = Locale.Language(identifier: "pt-BR")

        try await sut.prepareLanguages(from: source, into: target)

        #expect(backend.recordedPreparePairs == [LanguagePair(source: source, target: target)])
    }

    @Test func should_invoke_backend_prepare_exactly_once_when_called_once() async throws {
        let backend = FakeTranslationPackBackend()
        let sut = makeSUT(backend)

        try await sut.prepareLanguages(from: en, into: ru)

        #expect(backend.prepareCallCount == 1)
    }
}
