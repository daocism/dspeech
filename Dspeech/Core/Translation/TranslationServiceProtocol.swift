import Foundation

/// Whether a source→target language pair can be translated on this device right now.
///
/// Mirrors `Translation.LanguageAvailability.Status` (Apple Translation framework,
/// iOS 18.0+; verified against Apple DocC
/// `documentation/translation/languageavailability`). The Core layer never imports
/// the `Translation` framework — concrete adapters map that enum onto this one.
enum TranslationLanguageStatus: Equatable, Sendable {
    /// On-device language assets are installed; translation runs fully offline.
    case installed

    /// The pair is supported but its on-device assets are not installed yet.
    /// Acquiring them is an explicit, user-initiated action — see
    /// ``TranslationLanguagePackPreparer``.
    case downloadable

    /// The pair is not supported by the on-device translation engine.
    case unsupported
}

/// Typed failures from the on-device translation boundary.
///
/// Cases map 1:1 from `Translation.TranslationError` (iOS 18.0+; verified against
/// Apple DocC `documentation/translation/translationerror`). No case represents a
/// network or cloud condition: the conforming Core type performs **zero**
/// Dspeech-originated networking (ADR 0002, repo `CLAUDE.md` hard rule 2).
enum TranslationServiceError: Error, Equatable, Sendable {
    /// The input was empty or whitespace-only (`TranslationError.nothingToTranslate`).
    case emptyInput

    /// The engine does not support the requested source language
    /// (`TranslationError.unsupportedSourceLanguage`).
    case sourceLanguageUnsupported(Locale.Language)

    /// The engine does not support the requested target language
    /// (`TranslationError.unsupportedTargetLanguage`).
    case targetLanguageUnsupported(Locale.Language)

    /// The engine does not support this specific pairing
    /// (`TranslationError.unsupportedLanguagePairing`).
    case languagePairingUnsupported(source: Locale.Language, target: Locale.Language)

    /// On-device assets for this pair are not installed and translation was
    /// attempted anyway (`TranslationError.notInstalled`). The caller must route
    /// the user through ``TranslationLanguagePackPreparer`` first; it must never
    /// silently fall back to cloud.
    case languagePackNotInstalled(source: Locale.Language, target: Locale.Language)

    /// The session was cancelled before it could produce this result
    /// (`TranslationError.alreadyCancelled`).
    case sessionCancelled

    /// Any other engine-internal failure (`TranslationError.internalError` and
    /// otherwise-unmapped framework errors). The string is for the single
    /// subsystem log boundary only, never user-facing copy.
    case engineFailure(String)
}

/// On-device translation of a single finalized transcript segment.
///
/// Contract for F3 (PRD `docs/product/prd-ios-mvp.md` §1 "Translation toggle",
/// lines 30-34) under `PrivacyMode.localOnly`:
///
/// - Conforming Core types translate **only** with installed on-device assets via
///   Apple's `Translation` framework (`TranslationSession`, iOS 18.0+; verified
///   against Apple DocC `documentation/translation/translationsession`).
/// - Conforming Core types open **no** sockets or HTTP clients and never reach
///   `packs.dspeech.app` or any cloud MT endpoint (ADR 0002; the PLAN W7 gate
///   greps this directory for networking-class symbols and must find none).
/// - ``translate(_:from:into:)`` never downloads assets and never blocks ASR; on
///   a missing pair it throws ``TranslationServiceError/languagePackNotInstalled``
///   so the UI can show the explicit "Download pack" CTA.
///
/// `Sendable` because translation runs off the main actor and is injected into a
/// `@MainActor @Observable` view model (the `PrivacySettings` template). Methods
/// are `async` so isolation is correct under both Swift 6.0 nonisolated-default
/// and a future Swift 6.2 main-actor-default migration.
protocol TranslationService: Sendable {
    /// Reports whether `source`→`target` can be translated on-device right now.
    ///
    /// Wraps `LanguageAvailability.status(from:to:)` (async, non-throwing per
    /// Apple DocC). Languages are `Locale.Language`, never BCP-47 `String`.
    func availability(
        translatingFrom source: Locale.Language,
        into target: Locale.Language
    ) async -> TranslationLanguageStatus

    /// Translates one finalized segment using installed on-device assets only.
    ///
    /// - Throws: ``TranslationServiceError`` — in particular
    ///   ``TranslationServiceError/languagePackNotInstalled(source:target:)`` when
    ///   assets are absent. Never returns a partial or cloud-derived result.
    func translate(
        _ text: String,
        from source: Locale.Language,
        into target: Locale.Language
    ) async throws(TranslationServiceError) -> String
}

/// Explicit, user-initiated acquisition of on-device translation assets.
///
/// Separated from ``TranslationService`` because Apple gates first-time asset
/// download behind a **system-presented UI**: the only public routes are the
/// SwiftUI `.translationTask` modifier and `TranslationSession.prepareTranslation()`
/// (iOS 18.0+; verified against Apple DocC
/// `documentation/translation/translationsession/preparetranslation()`). There is
/// no programmatic silent downloader.
///
/// The single conforming implementation therefore lives at the SwiftUI integration
/// seam, not in pure Core. It performs **no** Dspeech-originated networking — Apple
/// owns the asset transport, analogous to the keyboard/dictation model download and
/// the "metadata for software updates" carve-out in
/// `docs/product/language-pack-spec.md`. It is invoked only from the explicit
/// "Download pack — N MB" control (PRD §1 line 33), never implicitly and never
/// under `PrivacyMode.localOnly` without that tap.
protocol TranslationLanguagePackPreparer: Sendable {
    /// Presents Apple's system download flow for the `source`→`target` assets and
    /// resolves once they are installed.
    ///
    /// - Throws: ``TranslationServiceError`` —
    ///   ``TranslationServiceError/languagePairingUnsupported(source:target:)`` if
    ///   the pair can never be installed, ``TranslationServiceError/sessionCancelled``
    ///   if the user dismisses the system sheet.
    func prepareLanguages(
        from source: Locale.Language,
        into target: Locale.Language
    ) async throws(TranslationServiceError)
}
