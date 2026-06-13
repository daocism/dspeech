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

  @Test func appleTranslationAvailabilityMatchesFrameworkStatusBeforeSessionBoundary() async {
    let service = AppleTranslationService()
    let frameworkAvailability = LanguageAvailability()
    let pairs = [
      (source: en, target: ru),
      (source: en, target: Locale.Language(identifier: "fr")),
      (source: en, target: Locale.Language(identifier: "zz")),
    ]

    for pair in pairs {
      let frameworkStatus = await frameworkAvailability.status(from: pair.source, to: pair.target)
      let adapterStatus = await service.availability(
        translatingFrom: pair.source,
        into: pair.target
      )
      #expect(adapterStatus == Self.status(from: frameworkStatus))
    }
  }

  @Test func appleTranslationRejectsEmptyInputBeforeAvailabilityOrSession() async {
    do {
      _ = try await AppleTranslationService().translate(" \n\t ", from: en, into: ru)
      Issue.record("expected emptyInput")
    } catch {
      #expect(error == .emptyInput)
    }
  }

  @Test func serviceErrorsMapToVisibleTranslationFailures() {
    let failures: [(TranslationServiceError, TranslationFailure)] = [
      (.emptyInput, .emptyInput),
      (.sourceLanguageUnsupported(en), .sourceLanguageUnsupported(en)),
      (.targetLanguageUnsupported(ru), .targetLanguageUnsupported(ru)),
      (
        .languagePairingUnsupported(source: en, target: ru),
        .languagePairingUnsupported(source: en, target: ru)
      ),
      (
        .languagePackNotInstalled(source: en, target: ru),
        .languagePackNotInstalled(source: en, target: ru)
      ),
      (.sessionCancelled, .sessionCancelled),
      (.engineFailure("TranslationBackend#42"), .engineFailure("TranslationBackend#42")),
    ]

    for (error, expected) in failures {
      #expect(TranslationFailure.service(error) == expected)
    }
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

  private static func status(
    from frameworkStatus: LanguageAvailability.Status
  ) -> TranslationLanguageStatus {
    switch frameworkStatus {
    case .installed:
      return .installed
    case .supported:
      return .downloadable
    case .unsupported:
      return .unsupported
    @unknown default:
      return .unsupported
    }
  }

  #if DEBUG
    @Test func scriptedEngineFactoryRequiresUITestLaunchArgument() {
      #expect(ScriptedLiveTranscriptionEngine.makeFromLaunchArguments(["Dspeech"]) == nil)
    }

    @Test func scriptedEngineEmitsDeterministicLaunchScript() async throws {
      let engine = try #require(
        ScriptedLiveTranscriptionEngine.makeFromLaunchArguments([
          "Dspeech",
          "-dspeech.uitest.scripted-engine",
        ]))
      var iterator = engine.events().makeAsyncIterator()

      await engine.start()

      try Self.expectStatus(await iterator.next(), .idle)
      try Self.expectStatus(await iterator.next(), .requestingPermission)
      try Self.expectStatus(await iterator.next(), .listening)
      try Self.expectPartial(await iterator.next(), "Tower N123AB")
      let segment = try Self.requireSegment(await iterator.next())
      #expect(segment.text == "Tower N123AB cleared for takeoff")
      #expect(segment.confidence == 0.96)
      #expect(segment.source == .liveATC)
      try Self.expectStatus(await iterator.next(), .stopped)
      #expect(engine.status == .stopped)
    }

    private static func expectStatus(
      _ event: LiveTranscriptionEvent?,
      _ expected: LiveTranscriptionStatus
    ) throws {
      guard case .status(let status) = try #require(event) else {
        Issue.record("expected status \(expected)")
        return
      }
      #expect(status == expected)
    }

    private static func expectPartial(
      _ event: LiveTranscriptionEvent?,
      _ expected: String
    ) throws {
      guard case .partial(let text) = try #require(event) else {
        Issue.record("expected partial \(expected)")
        return
      }
      #expect(text == expected)
    }

    private static func requireSegment(
      _ event: LiveTranscriptionEvent?
    ) throws -> TranscriptSegment {
      guard case .segment(let segment, _) = try #require(event) else {
        Issue.record("expected segment")
        throw TestExpectationFailure()
      }
      return segment
    }

    private struct TestExpectationFailure: Error {}
  #endif
}
