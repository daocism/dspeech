import Foundation
import Translation

// Apple Translation framework adapter. API verified against Apple DocC + the
// iOS 26.4 SDK: TranslationSession.init(installedSource:target:) is synchronous
// and non-throwing (installed-only), translate(_:) is async throws, and
// LanguageAvailability.status(from:to:) is async non-throwing. Performs zero
// Dspeech-originated networking — Apple owns any asset transport (ADR 0002).
struct AppleTranslationService: TranslationService {
  func availability(
    translatingFrom source: Locale.Language,
    into target: Locale.Language
  ) async -> TranslationLanguageStatus {
    let sourceCode = source.languageCode?.identifier ?? "unknown"
    let targetCode = target.languageCode?.identifier ?? "unknown"
    let status: TranslationLanguageStatus
    switch await LanguageAvailability().status(from: source, to: target) {
    case .installed:
      status = .installed
    case .supported:
      status = .downloadable
    case .unsupported:
      status = .unsupported
    @unknown default:
      status = .unsupported
    }
    DspeechLog.translation.info(
      "translation availability source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public) status=\(String(describing: status), privacy: .public)"
    )
    return status
  }

  func translate(
    _ text: String,
    from source: Locale.Language,
    into target: Locale.Language
  ) async throws(TranslationServiceError) -> String {
    let sourceCode = source.languageCode?.identifier ?? "unknown"
    let targetCode = target.languageCode?.identifier ?? "unknown"
    DspeechLog.translation.info(
      "apple translation request source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public)"
    )
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      DspeechLog.translation.error(
        "apple translation failed source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public) kind=emptyInput"
      )
      throw .emptyInput
    }

    // why: pre-check availability so the languagePackNotInstalled contract holds
    // deterministically — init(installedSource:target:) only surfaces a missing
    // pair lazily on translate, and this method never downloads assets.
    switch await availability(translatingFrom: source, into: target) {
    case .installed: break
    case .downloadable:
      DspeechLog.translation.error(
        "apple translation failed source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public) kind=languagePackNotInstalled"
      )
      throw .languagePackNotInstalled(source: source, target: target)
    case .unsupported:
      DspeechLog.translation.error(
        "apple translation failed source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public) kind=languagePairingUnsupported"
      )
      throw .languagePairingUnsupported(source: source, target: target)
    }

    do {
      let session = TranslationSession(installedSource: source, target: target)
      let response = try await session.translate(trimmed)
      DspeechLog.translation.info(
        "apple translation succeeded source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public)"
      )
      return response.targetText
    } catch TranslationError.nothingToTranslate {
      DspeechLog.translation.error(
        "apple translation failed source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public) kind=emptyInput"
      )
      throw .emptyInput
    } catch TranslationError.notInstalled {
      DspeechLog.translation.error(
        "apple translation failed source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public) kind=languagePackNotInstalled"
      )
      throw .languagePackNotInstalled(source: source, target: target)
    } catch TranslationError.unsupportedSourceLanguage {
      DspeechLog.translation.error(
        "apple translation failed source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public) kind=sourceLanguageUnsupported"
      )
      throw .sourceLanguageUnsupported(source)
    } catch TranslationError.unsupportedTargetLanguage {
      DspeechLog.translation.error(
        "apple translation failed source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public) kind=targetLanguageUnsupported"
      )
      throw .targetLanguageUnsupported(target)
    } catch TranslationError.unsupportedLanguagePairing {
      DspeechLog.translation.error(
        "apple translation failed source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public) kind=languagePairingUnsupported"
      )
      throw .languagePairingUnsupported(source: source, target: target)
    } catch TranslationError.alreadyCancelled {
      DspeechLog.translation.error(
        "apple translation failed source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public) kind=sessionCancelled"
      )
      throw .sessionCancelled
    } catch is CancellationError {
      DspeechLog.translation.error(
        "apple translation failed source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public) kind=sessionCancelled"
      )
      throw .sessionCancelled
    } catch {
      DspeechLog.translation.error(
        "apple translation failed source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public) kind=engineFailure error=\(String(describing: error))"
      )
      throw .engineFailure(String(describing: error))
    }
  }
}

// Host-testable pure decorator over the un-fakeable Apple shell (functional core,
// imperative shell). Forwards trimmed input so the empty-input guard and the
// backend see the same text (no asymmetric-trim ambiguity).
struct LocalTranslationService: TranslationService {
  private let backend: any TranslationService

  init(backend: any TranslationService) {
    self.backend = backend
  }

  func availability(
    translatingFrom source: Locale.Language,
    into target: Locale.Language
  ) async -> TranslationLanguageStatus {
    let status = await backend.availability(translatingFrom: source, into: target)
    let sourceCode = source.languageCode?.identifier ?? "unknown"
    let targetCode = target.languageCode?.identifier ?? "unknown"
    DspeechLog.translation.info(
      "local translation availability source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public) status=\(String(describing: status), privacy: .public)"
    )
    return status
  }

  func translate(
    _ text: String,
    from source: Locale.Language,
    into target: Locale.Language
  ) async throws(TranslationServiceError) -> String {
    let sourceCode = source.languageCode?.identifier ?? "unknown"
    let targetCode = target.languageCode?.identifier ?? "unknown"
    DspeechLog.translation.info(
      "local translation request source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public)"
    )
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      DspeechLog.translation.error(
        "local translation failed source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public) kind=emptyInput"
      )
      throw .emptyInput
    }
    do {
      let translated = try await backend.translate(trimmed, from: source, into: target)
      DspeechLog.translation.info(
        "local translation succeeded source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public)"
      )
      return translated
    } catch {
      let kind: String
      switch error {
      case .emptyInput:
        kind = "emptyInput"
      case .sourceLanguageUnsupported:
        kind = "sourceLanguageUnsupported"
      case .targetLanguageUnsupported:
        kind = "targetLanguageUnsupported"
      case .languagePairingUnsupported:
        kind = "languagePairingUnsupported"
      case .languagePackNotInstalled:
        kind = "languagePackNotInstalled"
      case .sessionCancelled:
        kind = "sessionCancelled"
      case .engineFailure:
        kind = "engineFailure"
      }
      DspeechLog.translation.error(
        "local translation failed source=\(sourceCode, privacy: .public) target=\(targetCode, privacy: .public) kind=\(kind, privacy: .public)"
      )
      throw error
    }
  }
}

extension TranslationFailure {
  static func preparation(
    _ error: any Error,
    source: Locale.Language,
    target: Locale.Language
  ) -> TranslationFailure {
    switch error {
    case TranslationError.notInstalled:
      return .languagePackNotInstalled(source: source, target: target)
    case TranslationError.unsupportedSourceLanguage:
      return .sourceLanguageUnsupported(source)
    case TranslationError.unsupportedTargetLanguage:
      return .targetLanguageUnsupported(target)
    case TranslationError.unsupportedLanguagePairing:
      return .languagePairingUnsupported(source: source, target: target)
    case TranslationError.alreadyCancelled:
      return .preparationCancelled
    case is CancellationError:
      return .preparationCancelled
    default:
      return .preparationFailed(String(describing: error))
    }
  }
}
