import Foundation

enum TranslationLanguageStatus: Equatable, Sendable {
  case installed
  case downloadable
  case unsupported
}

enum TranslationServiceError: Error, Equatable, Sendable {
  case emptyInput
  case sourceLanguageUnsupported(Locale.Language)
  case targetLanguageUnsupported(Locale.Language)
  case languagePairingUnsupported(source: Locale.Language, target: Locale.Language)
  case languagePackNotInstalled(source: Locale.Language, target: Locale.Language)
  case sessionCancelled
  case engineFailure(String)
}

enum TranslationFailure: Equatable, Sendable {
  case emptyInput
  case sourceLanguageUnsupported(Locale.Language)
  case targetLanguageUnsupported(Locale.Language)
  case languagePairingUnsupported(source: Locale.Language, target: Locale.Language)
  case languagePackNotInstalled(source: Locale.Language, target: Locale.Language)
  case sessionCancelled
  case preparationCancelled
  case preparationFailed(String)
  case engineFailure(String)

  static func service(_ error: TranslationServiceError) -> TranslationFailure {
    switch error {
    case .emptyInput:
      return .emptyInput
    case .sourceLanguageUnsupported(let source):
      return .sourceLanguageUnsupported(source)
    case .targetLanguageUnsupported(let target):
      return .targetLanguageUnsupported(target)
    case .languagePairingUnsupported(let source, let target):
      return .languagePairingUnsupported(source: source, target: target)
    case .languagePackNotInstalled(let source, let target):
      return .languagePackNotInstalled(source: source, target: target)
    case .sessionCancelled:
      return .sessionCancelled
    case .engineFailure(let message):
      return .engineFailure(message)
    }
  }
}

// On-device translation of one finalized transcript segment (PRD F3, ADR 0002).
// Conforming types translate only with installed on-device assets via Apple's
// Translation framework and open no network path. `Sendable` so the concrete
// service runs off the main actor behind a @MainActor view model.
protocol TranslationService: Sendable {
  func availability(
    translatingFrom source: Locale.Language,
    into target: Locale.Language
  ) async -> TranslationLanguageStatus

  // why: typed throws so the caller can branch on languagePackNotInstalled to
  // surface the explicit download CTA, never a silent cloud fallback.
  func translate(
    _ text: String,
    from source: Locale.Language,
    into target: Locale.Language
  ) async throws(TranslationServiceError) -> String
}
