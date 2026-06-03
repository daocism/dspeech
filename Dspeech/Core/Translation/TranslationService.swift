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
    switch await LanguageAvailability().status(from: source, to: target) {
    case .installed: return .installed
    case .supported: return .downloadable
    case .unsupported: return .unsupported
    @unknown default: return .unsupported
    }
  }

  func translate(
    _ text: String,
    from source: Locale.Language,
    into target: Locale.Language
  ) async throws(TranslationServiceError) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw .emptyInput }

    // why: pre-check availability so the languagePackNotInstalled contract holds
    // deterministically — init(installedSource:target:) only surfaces a missing
    // pair lazily on translate, and this method never downloads assets.
    switch await availability(translatingFrom: source, into: target) {
    case .installed: break
    case .downloadable: throw .languagePackNotInstalled(source: source, target: target)
    case .unsupported: throw .languagePairingUnsupported(source: source, target: target)
    }

    do {
      let session = TranslationSession(installedSource: source, target: target)
      let response = try await session.translate(trimmed)
      return response.targetText
    } catch TranslationError.nothingToTranslate {
      throw .emptyInput
    } catch TranslationError.notInstalled {
      throw .languagePackNotInstalled(source: source, target: target)
    } catch TranslationError.unsupportedSourceLanguage {
      throw .sourceLanguageUnsupported(source)
    } catch TranslationError.unsupportedTargetLanguage {
      throw .targetLanguageUnsupported(target)
    } catch TranslationError.unsupportedLanguagePairing {
      throw .languagePairingUnsupported(source: source, target: target)
    } catch TranslationError.alreadyCancelled {
      throw .sessionCancelled
    } catch is CancellationError {
      throw .sessionCancelled
    } catch {
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
    await backend.availability(translatingFrom: source, into: target)
  }

  func translate(
    _ text: String,
    from source: Locale.Language,
    into target: Locale.Language
  ) async throws(TranslationServiceError) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw .emptyInput }
    return try await backend.translate(trimmed, from: source, into: target)
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
