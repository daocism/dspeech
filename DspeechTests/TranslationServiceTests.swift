import Foundation
import Testing
import Translation

@testable import Dspeech

@MainActor
struct TranslationServiceTests {
  private let en = Locale.Language(identifier: "en")
  private let ru = Locale.Language(identifier: "ru")

  private func makeSUT(_ backend: FakeTranslationBackend) -> LocalTranslationService {
    LocalTranslationService(backend: backend)
  }

  @Test func availabilityPassesThroughInstalled() async {
    let backend = FakeTranslationBackend()
    backend.statusToReturn = .installed
    let status = await makeSUT(backend).availability(translatingFrom: en, into: ru)
    #expect(status == .installed)
    #expect(backend.availabilityCallCount == 1)
  }

  @Test func availabilityPassesThroughDownloadable() async {
    let backend = FakeTranslationBackend()
    backend.statusToReturn = .downloadable
    let status = await makeSUT(backend).availability(translatingFrom: en, into: ru)
    #expect(status == .downloadable)
  }

  @Test func availabilityPassesThroughUnsupported() async {
    let backend = FakeTranslationBackend()
    backend.statusToReturn = .unsupported
    let status = await makeSUT(backend).availability(translatingFrom: en, into: ru)
    #expect(status == .unsupported)
  }

  @Test func throwsEmptyInputOnEmptyText() async {
    let backend = FakeTranslationBackend()
    let sut = makeSUT(backend)
    do {
      _ = try await sut.translate("", from: en, into: ru)
      Issue.record("expected emptyInput")
    } catch {
      #expect(error == .emptyInput)
    }
    #expect(backend.translateCallCount == 0)
  }

  @Test func throwsEmptyInputOnWhitespaceOnly() async {
    let backend = FakeTranslationBackend()
    let sut = makeSUT(backend)
    do {
      _ = try await sut.translate("  \n\t ", from: en, into: ru)
      Issue.record("expected emptyInput")
    } catch {
      #expect(error == .emptyInput)
    }
    #expect(backend.translateCallCount == 0)
  }

  @Test func forwardsTrimmedTextToBackend() async throws {
    let backend = FakeTranslationBackend()
    backend.translationResult = "ok"
    let sut = makeSUT(backend)
    _ = try await sut.translate("  descend three thousand  ", from: en, into: ru)
    #expect(backend.recordedInputs == ["descend three thousand"])
  }

  @Test func returnsBackendTranslation() async throws {
    let backend = FakeTranslationBackend()
    backend.translationResult = "Снижайтесь до трёх тысяч"
    let result = try await makeSUT(backend)
      .translate("Descend and maintain three thousand", from: en, into: ru)
    #expect(result == "Снижайтесь до трёх тысяч")
    #expect(backend.translateCallCount == 1)
  }

  @Test func propagatesLanguagePackNotInstalled() async {
    let backend = FakeTranslationBackend()
    backend.translateError = .languagePackNotInstalled(source: en, target: ru)
    do {
      _ = try await makeSUT(backend).translate("roger", from: en, into: ru)
      Issue.record("expected languagePackNotInstalled")
    } catch {
      #expect(error == .languagePackNotInstalled(source: en, target: ru))
    }
  }

  @Test func propagatesUnsupportedPairing() async {
    let backend = FakeTranslationBackend()
    backend.translateError = .languagePairingUnsupported(source: en, target: ru)
    do {
      _ = try await makeSUT(backend).translate("roger", from: en, into: ru)
      Issue.record("expected languagePairingUnsupported")
    } catch {
      #expect(error == .languagePairingUnsupported(source: en, target: ru))
    }
  }

  @Test func preparationNotInstalledMapsToLanguagePackFailure() {
    let failure = TranslationFailure.preparation(
      TranslationError.notInstalled, source: en, target: ru)
    #expect(failure == .languagePackNotInstalled(source: en, target: ru))
  }

  @Test func preparationUnsupportedPairMapsToPairFailure() {
    let failure = TranslationFailure.preparation(
      TranslationError.unsupportedLanguagePairing, source: en, target: ru)
    #expect(failure == .languagePairingUnsupported(source: en, target: ru))
  }

  @Test func preparationCancellationMapsToCancelled() {
    let failure = TranslationFailure.preparation(CancellationError(), source: en, target: ru)
    #expect(failure == .preparationCancelled)
  }

  @Test func preparationUnknownErrorMapsToPreparationFailure() {
    let error = NSError(domain: "TranslationBackend", code: 42)
    let failure = TranslationFailure.preparation(error, source: en, target: ru)
    guard case .preparationFailed(let message) = failure else {
      Issue.record("expected preparationFailed")
      return
    }
    #expect(message.contains("TranslationBackend"))
  }
}
