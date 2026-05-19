import Foundation
import Testing
@testable import Dspeech

@MainActor
struct TranslationServiceTests {
    private let en = Locale.Language(identifier: "en")
    private let ru = Locale.Language(identifier: "ru")
    private let uk = Locale.Language(identifier: "uk")

    private func makeSUT(_ backend: FakeTranslationBackend) -> LocalTranslationService {
        LocalTranslationService(backend: backend)
    }

    @Test func should_report_installed_when_backend_reports_installed() async {
        let backend = FakeTranslationBackend()
        backend.statusToReturn = .installed
        let sut = makeSUT(backend)

        let status = await sut.availability(translatingFrom: en, into: ru)

        #expect(status == .installed)
        #expect(backend.availabilityCallCount == 1)
    }

    @Test func should_report_downloadable_when_backend_reports_pack_not_installed() async {
        let backend = FakeTranslationBackend()
        backend.statusToReturn = .downloadable
        let sut = makeSUT(backend)

        let status = await sut.availability(translatingFrom: en, into: ru)

        #expect(status == .downloadable)
    }

    @Test func should_report_unsupported_when_backend_reports_unsupported_pair() async {
        let backend = FakeTranslationBackend()
        backend.statusToReturn = .unsupported
        let sut = makeSUT(backend)

        let status = await sut.availability(translatingFrom: en, into: ru)

        #expect(status == .unsupported)
    }

    @Test func should_throw_emptyInput_when_text_is_empty() async {
        let backend = FakeTranslationBackend()
        let sut = makeSUT(backend)

        do {
            _ = try await sut.translate("", from: en, into: ru)
            Issue.record("expected TranslationServiceError.emptyInput, returned a value")
        } catch {
            #expect(error == .emptyInput)
        }
    }

    @Test func should_throw_emptyInput_when_text_is_whitespace_only() async {
        let backend = FakeTranslationBackend()
        let sut = makeSUT(backend)

        do {
            _ = try await sut.translate("   \n\t  ", from: en, into: ru)
            Issue.record("expected TranslationServiceError.emptyInput, returned a value")
        } catch {
            #expect(error == .emptyInput)
        }
    }

    @Test func should_not_call_backend_translate_when_input_is_empty() async {
        let backend = FakeTranslationBackend()
        let sut = makeSUT(backend)

        do {
            _ = try await sut.translate("", from: en, into: ru)
            Issue.record("expected TranslationServiceError.emptyInput, returned a value")
        } catch {
            #expect(error == .emptyInput)
        }
        #expect(backend.translateCallCount == 0)
    }

    @Test func should_return_translation_when_pair_installed() async throws {
        let backend = FakeTranslationBackend()
        backend.translationResult = "Снижайтесь до трёх тысяч"
        let sut = makeSUT(backend)

        let result = try await sut.translate(
            "Descend and maintain three thousand",
            from: en,
            into: ru
        )

        #expect(result == "Снижайтесь до трёх тысяч")
        #expect(backend.translateCallCount == 1)
    }

    @Test func should_throw_languagePackNotInstalled_when_pack_missing() async {
        let backend = FakeTranslationBackend()
        backend.translateError = .languagePackNotInstalled(source: en, target: ru)
        let sut = makeSUT(backend)

        do {
            _ = try await sut.translate("roger", from: en, into: ru)
            Issue.record("expected TranslationServiceError.languagePackNotInstalled")
        } catch {
            #expect(error == .languagePackNotInstalled(source: en, target: ru))
        }
    }

    @Test func should_throw_sourceLanguageUnsupported_when_backend_rejects_source() async {
        let backend = FakeTranslationBackend()
        backend.translateError = .sourceLanguageUnsupported(en)
        let sut = makeSUT(backend)

        do {
            _ = try await sut.translate("roger", from: en, into: ru)
            Issue.record("expected TranslationServiceError.sourceLanguageUnsupported")
        } catch {
            #expect(error == .sourceLanguageUnsupported(en))
        }
    }

    @Test func should_throw_targetLanguageUnsupported_when_backend_rejects_target() async {
        let backend = FakeTranslationBackend()
        backend.translateError = .targetLanguageUnsupported(ru)
        let sut = makeSUT(backend)

        do {
            _ = try await sut.translate("roger", from: en, into: ru)
            Issue.record("expected TranslationServiceError.targetLanguageUnsupported")
        } catch {
            #expect(error == .targetLanguageUnsupported(ru))
        }
    }

    @Test func should_throw_languagePairingUnsupported_when_backend_rejects_pair() async {
        let backend = FakeTranslationBackend()
        backend.translateError = .languagePairingUnsupported(source: en, target: uk)
        let sut = makeSUT(backend)

        do {
            _ = try await sut.translate("roger", from: en, into: uk)
            Issue.record("expected TranslationServiceError.languagePairingUnsupported")
        } catch {
            #expect(error == .languagePairingUnsupported(source: en, target: uk))
        }
    }

    @Test func should_throw_sessionCancelled_when_translation_is_cancelled() async {
        let backend = FakeTranslationBackend()
        backend.translateError = .sessionCancelled
        let sut = makeSUT(backend)

        do {
            _ = try await sut.translate("roger", from: en, into: ru)
            Issue.record("expected TranslationServiceError.sessionCancelled")
        } catch {
            #expect(error == .sessionCancelled)
        }
    }

    @Test func should_throw_engineFailure_when_backend_reports_internal_error() async {
        let backend = FakeTranslationBackend()
        backend.translateError = .engineFailure("internalError")
        let sut = makeSUT(backend)

        do {
            _ = try await sut.translate("roger", from: en, into: ru)
            Issue.record("expected TranslationServiceError.engineFailure")
        } catch {
            #expect(error == .engineFailure("internalError"))
        }
    }

    @Test func should_translate_very_long_input_without_truncation_when_pair_installed() async throws {
        let backend = FakeTranslationBackend()
        let sut = makeSUT(backend)
        let longInput = String(
            repeating: "Cleared to land runway two seven left, wind two seven zero at one five. ",
            count: 300
        )

        let result = try await sut.translate(longInput, from: en, into: ru)

        #expect(longInput.count >= 10_000)
        #expect(result == longInput)
        #expect(result.count == longInput.count)
        #expect(backend.recordedInputs.first?.count == longInput.count)
    }

    @Test func should_preserve_locale_identifiers_when_querying_availability() async {
        let backend = FakeTranslationBackend()
        let sut = makeSUT(backend)
        let pairs = [
            LanguagePair(
                source: Locale.Language(identifier: "en-GB"),
                target: Locale.Language(identifier: "ru")
            ),
            LanguagePair(
                source: Locale.Language(identifier: "zh-Hans"),
                target: Locale.Language(identifier: "en")
            ),
            LanguagePair(
                source: Locale.Language(identifier: "pt-BR"),
                target: Locale.Language(identifier: "uk")
            ),
        ]

        for pair in pairs {
            _ = await sut.availability(translatingFrom: pair.source, into: pair.target)
        }

        #expect(backend.recordedAvailabilityPairs == pairs)
    }

    @Test func should_preserve_locale_identifiers_when_translating() async throws {
        let backend = FakeTranslationBackend()
        backend.translationResult = "ok"
        let sut = makeSUT(backend)
        let source = Locale.Language(identifier: "en-US")
        let target = Locale.Language(identifier: "pt-BR")

        _ = try await sut.translate("ready", from: source, into: target)

        #expect(backend.recordedTranslatePairs == [LanguagePair(source: source, target: target)])
    }

    @Test func should_return_backend_translation_verbatim_including_unicode() async throws {
        let backend = FakeTranslationBackend()
        backend.translationResult = "Снижайтесь, выдерживайте 3000 футов — ветер 270° 15 узлов"
        let sut = makeSUT(backend)

        let result = try await sut.translate("Descend, maintain 3000 ft", from: en, into: ru)

        #expect(result == "Снижайтесь, выдерживайте 3000 футов — ветер 270° 15 узлов")
    }

    @Test func should_translate_good_pair_after_querying_unsupported_pair() async throws {
        let backend = FakeTranslationBackend()
        backend.statusToReturn = .unsupported
        let sut = makeSUT(backend)

        let status = await sut.availability(translatingFrom: en, into: ru)
        #expect(status == .unsupported)

        backend.statusToReturn = .installed
        backend.translationResult = "вас понял"
        let result = try await sut.translate("roger", from: en, into: ru)

        #expect(result == "вас понял")
    }
}
