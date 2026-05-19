import Foundation
import Translation

/// The single OS-gated step of pack acquisition, isolated behind a `Sendable`
/// port so the Core layer stays SwiftUI-free.
///
/// Apple exposes **no** programmatic downloader for an absent language pair:
/// `TranslationSession.init(installedSource:target:)` is installed-only and
/// throws otherwise, and `prepareTranslation()` requires a `TranslationSession`
/// that only the SwiftUI `.translationTask(_:action:)` modifier can mint for a
/// not-yet-installed pair (verified against Apple DocC
/// `documentation/translation/translationsession{,/preparetranslation()}` and
/// `…/translationsession/configuration`, 2026-05-19; restated in the frozen
/// ``TranslationLanguagePackPreparer`` DocC).
///
/// The conforming type therefore lives at the SwiftUI integration seam and is
/// supplied by W5 (`docs/architecture-mvp-slice-2026-05-19.md`: "W2a model + W5
/// stitch"). It performs Apple's system-presented download flow and **no**
/// Dspeech-originated networking — Apple owns the asset transport, the same
/// class as the keyboard/dictation model fetch (ADR 0002).
protocol TranslationPackSystemDownloadPort: Sendable {
    /// Presents Apple's system download UI for the `source`→`target` assets via
    /// a `.translationTask`-provided `TranslationSession.prepareTranslation()`
    /// and resolves once they are installed.
    ///
    /// - Throws: ``TranslationServiceError`` — never a network/cloud case
    ///   (none exists on this type), only
    ///   ``TranslationServiceError/sessionCancelled`` if the user dismisses the
    ///   sheet or ``TranslationServiceError/languagePairingUnsupported(source:target:)``
    ///   if the pair can never be installed.
    func requestSystemDownload(
        from source: Locale.Language,
        into target: Locale.Language
    ) async throws(TranslationServiceError)
}

/// On-device implementation of ``TranslationLanguagePackPreparer``.
///
/// Availability-gates the request via `LanguageAvailability.status(from:to:)`
/// (async, non-throwing; Apple DocC
/// `documentation/translation/languageavailability/status(from:to:)`) and then:
///
/// - `.installed` → assets already present; preparing a prepared pair is a
///   successful no-op (the postcondition "installed" already holds).
/// - `.supported` → supported but not installed: the only acquisition route is
///   Apple's system UI, delegated to the injected
///   ``TranslationPackSystemDownloadPort`` (wired by W5 at the SwiftUI seam).
/// - `.unsupported` → throws
///   ``TranslationServiceError/languagePairingUnsupported(source:target:)``.
///
/// Performs **zero** Dspeech-originated networking (ADR 0002; PLAN W7 greps this
/// directory for networking-class symbols and must find none). Stateless `struct`
/// holding only a `Sendable` port → implicitly `Sendable`.
struct AppleTranslationLanguagePackManager: TranslationLanguagePackPreparer {
    private let systemDownloadPort: any TranslationPackSystemDownloadPort

    init(systemDownloadPort: any TranslationPackSystemDownloadPort) {
        self.systemDownloadPort = systemDownloadPort
    }

    func prepareLanguages(
        from source: Locale.Language,
        into target: Locale.Language
    ) async throws(TranslationServiceError) {
        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed:
            return
        case .supported:
            try await systemDownloadPort.requestSystemDownload(from: source, into: target)
        case .unsupported:
            throw .languagePairingUnsupported(source: source, target: target)
        @unknown default:
            throw .languagePairingUnsupported(source: source, target: target)
        }
    }
}
