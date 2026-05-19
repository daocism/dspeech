import Foundation
import Translation

/// On-device implementation of ``TranslationService`` backed by Apple's
/// `Translation` framework (iOS 18.0+; the project deployment target is iOS 26.0,
/// so no `@available` gate is required).
///
/// API surface verified against Apple's official DocC JSON
/// (`developer.apple.com/tutorials/data/documentation/translation/*.json`,
/// 2026-05-19) — the anti-hallucination "fetch current docs" branch of repo
/// `CLAUDE.md`, because the Context7 MCP is not mounted in this build env (same
/// substitution recorded by W1 in `docs/handoff.md`):
///
/// - `LanguageAvailability` → `documentation/translation/languageavailability`
/// - `LanguageAvailability.status(from:to:)` →
///   `…/languageavailability/status(from:to:)` (async, **non-throwing**)
/// - `TranslationSession.init(installedSource:target:)` →
///   `…/translationsession/init(installedsource:target:)` (throwing,
///   **synchronous**, installed-only)
/// - `TranslationSession.translate(_:)` →
///   `…/translationsession/translate(_:)` (async, throwing) returning
///   `TranslationSession.Response`
/// - `TranslationSession.Response.targetText` →
///   `…/translationsession/response/targettext` (`String`)
/// - `TranslationError` → `documentation/translation/translationerror`
///   (a `struct` with `static let` cases + `~=`, conforms to `Error`)
///
/// Performs **zero** Dspeech-originated networking: the only transport on this
/// path is Apple's OS-level model fetch, owned entirely by the system (ADR 0002,
/// repo `CLAUDE.md` hard rule 2). The PLAN W7 gate greps this directory for
/// networking-class symbols and must find none.
///
/// Stateless `struct` so it is trivially `Sendable` and pure at the call seam;
/// every Apple object (`LanguageAvailability`, `TranslationSession`) is a local
/// confined to a single async region and never escapes.
struct AppleTranslationService: TranslationService {
    /// Reports whether `source`→`target` can be translated on-device right now.
    ///
    /// Wraps `LanguageAvailability.status(from:to:)` (async, non-throwing per
    /// Apple DocC `documentation/translation/languageavailability/status(from:to:)`).
    /// `LanguageAvailability.Status` maps onto ``TranslationLanguageStatus``:
    /// `.installed`→``TranslationLanguageStatus/installed``,
    /// `.supported`→``TranslationLanguageStatus/downloadable`` (supported but
    /// assets not yet installed), `.unsupported`→
    /// ``TranslationLanguageStatus/unsupported``.
    func availability(
        translatingFrom source: Locale.Language,
        into target: Locale.Language
    ) async -> TranslationLanguageStatus {
        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
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

    /// Translates one finalized segment using installed on-device assets only.
    ///
    /// Pre-checks ``availability(translatingFrom:into:)`` so the
    /// ``TranslationServiceError/languagePackNotInstalled(source:target:)``
    /// contract holds deterministically regardless of which `TranslationError`
    /// `init(installedSource:target:)` surfaces for a missing pair — this method
    /// never downloads assets (per protocol DocC; the explicit "Download pack"
    /// CTA routes through ``TranslationLanguagePackPreparer`` instead).
    ///
    /// On the installed path it constructs a session via
    /// `TranslationSession.init(installedSource:target:)` (synchronous, throwing;
    /// Apple DocC `…/translationsession/init(installedsource:target:)`) and reads
    /// `Response.targetText`. Apple errors are mapped to ``TranslationServiceError``
    /// at this single boundary; nothing is swallowed.
    func translate(
        _ text: String,
        from source: Locale.Language,
        into target: Locale.Language
    ) async throws(TranslationServiceError) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyInput }

        switch await availability(translatingFrom: source, into: target) {
        case .installed:
            break
        case .downloadable:
            throw .languagePackNotInstalled(source: source, target: target)
        case .unsupported:
            throw .languagePairingUnsupported(source: source, target: target)
        }

        do {
            let session = try TranslationSession(installedSource: source, target: target)
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
