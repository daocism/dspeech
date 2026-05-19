import SwiftUI
import Translation

/// The shipped Settings sheet (PRD §2). Composes the existing Privacy +
/// Recognition controls with W4's `AudioSourceSettingsSection`,
/// `TranslationSettingsSection`, and `AboutSettingsSection`. The original
/// `DspeechUITests` contract is preserved verbatim: navigation title
/// "Настройки", `cloud-toggle`, `settings-done-button`, `settings-sheet`.
struct SettingsSheet: View {
    @Bindable var privacy: PrivacySettings
    let audioService: any AudioInputService
    let translationService: any TranslationService
    @Binding var targetLanguageCode: String
    let onSelectTargetLanguage: (Locale.Language) -> Void

    @State private var packCoordinator = TranslationPackDownloadCoordinator()
    @Environment(\.dismiss) private var dismiss

    private var packPreparer: any TranslationLanguagePackPreparer {
        TranslationLanguagePackManager(
            backend: AppleTranslationLanguagePackManager(
                systemDownloadPort: SwiftUITranslationPackDownloadPort(coordinator: packCoordinator)
            )
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $privacy.allowCloud) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Разрешить облачную обработку")
                                .font(.body.weight(.medium))
                            Text(privacy.allowCloud
                                 ? "Аудио и расшифровки могут уходить с устройства."
                                 : "Аудио остаётся на устройстве. Облако выключено.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("cloud-toggle")
                } header: {
                    Text("Приватность")
                } footer: {
                    Text("По умолчанию Dspeech обрабатывает звук только локально. Облако включается явно и видно по бейджу LOCAL/CLOUD на главном экране.")
                }

                Section("Распознавание") {
                    LabeledContent("Язык по умолчанию", value: "Авто")
                    LabeledContent("Модель ASR", value: "Apple Speech")
                    LabeledContent("Режим", value: privacy.mode.displayName)
                }

                AudioSourceSettingsSection(service: audioService)

                TranslationSettingsSection(
                    service: translationService,
                    preparer: packPreparer,
                    selectedLanguageCode: targetLanguageCode,
                    onSelectTargetLanguage: onSelectTargetLanguage
                )

                AboutSettingsSection()
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        dismiss()
                    }
                    .accessibilityIdentifier("settings-done-button")
                }
            }
        }
        .translationTask(packCoordinator.configuration) { @Sendable [packCoordinator] session in
            let outcome: TranslationPackDownloadOutcome
            do {
                try await session.prepareTranslation()
                outcome = .prepared
            } catch TranslationError.unsupportedLanguagePairing {
                outcome = .pairingUnsupported
            } catch TranslationError.alreadyCancelled {
                outcome = .cancelled
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .engineFailure(String(describing: error))
            }
            await packCoordinator.resolve(outcome)
        }
        .accessibilityIdentifier("settings-sheet")
        .preferredColorScheme(.dark)
    }
}

/// The single OS-gated step of language-pack acquisition, hosted at the SwiftUI
/// seam exactly as the frozen `TranslationPackSystemDownloadPort` DocC and the
/// architecture ("W2a model + W5 stitch") require: Apple exposes **no**
/// programmatic downloader for an absent pair — the only route is a
/// `.translationTask(_:action:)`-provided `TranslationSession` on which
/// `prepareTranslation()` presents Apple's own system download UI.
///
/// API verified against Apple's official DocC JSON (2026-05-19), the
/// anti-hallucination "fetch current docs" branch of repo `CLAUDE.md` (Context7
/// MCP not mounted in this env — the same substitution W1/W2/W3 recorded in
/// `docs/handoff.md`):
/// - `documentation/translation/translationsession/configuration` —
///   `TranslationSession.Configuration(source:target:)`, `Equatable`, the
///   `.translationTask` trigger.
/// - `documentation/translation/translationsession/preparetranslation()` —
///   `func prepareTranslation() async throws`.
/// - `documentation/translation/translationerror` — struct, `static let` cases
///   + `~=` (`unsupportedLanguagePairing`, `alreadyCancelled`).
///
/// Performs **zero** Dspeech-originated networking — Apple owns the asset
/// transport, the same class as the keyboard/dictation model fetch (ADR 0002).
@MainActor
@Observable
final class TranslationPackDownloadCoordinator {
    var configuration: TranslationSession.Configuration?

    @ObservationIgnored private var continuation: CheckedContinuation<Void, any Error>?
    @ObservationIgnored private var pendingPair: (source: Locale.Language, target: Locale.Language)?

    /// Drives the `.translationTask` modifier by publishing a configuration and
    /// suspends until ``resolve(_:)`` resolves the system flow. Maps every
    /// outcome onto the frozen typed error (never a network case — none exists).
    func requestDownload(
        from source: Locale.Language,
        into target: Locale.Language
    ) async throws(TranslationServiceError) {
        guard continuation == nil else {
            throw TranslationServiceError.engineFailure("pack download already in progress")
        }
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                self.continuation = cont
                self.pendingPair = (source, target)
                self.configuration = TranslationSession.Configuration(source: source, target: target)
            }
        } catch let error as TranslationServiceError {
            throw error
        } catch is CancellationError {
            throw TranslationServiceError.sessionCancelled
        } catch {
            throw TranslationServiceError.engineFailure(String(describing: error))
        }
    }

    /// Resolves the pending request from the `.translationTask` closure's
    /// Sendable classification of `prepareTranslation()`. The non-Sendable
    /// `TranslationSession` is owned and awaited entirely inside that nonisolated
    /// closure, so it never crosses into this `@MainActor` actor (Swift 6 strict
    /// concurrency); user-dismiss/cancel → ``TranslationServiceError/sessionCancelled``.
    func resolve(_ outcome: TranslationPackDownloadOutcome) {
        guard let cont = continuation else { return }
        let pair = pendingPair
        continuation = nil
        pendingPair = nil
        configuration = nil
        switch outcome {
        case .prepared:
            cont.resume()
        case .pairingUnsupported:
            let undetermined = Locale.Language(identifier: "und")
            cont.resume(throwing: TranslationServiceError.languagePairingUnsupported(
                source: pair?.source ?? undetermined,
                target: pair?.target ?? undetermined
            ))
        case .cancelled:
            cont.resume(throwing: TranslationServiceError.sessionCancelled)
        case .engineFailure(let message):
            cont.resume(throwing: TranslationServiceError.engineFailure(message))
        }
    }
}

/// Sendable classification of the `.translationTask` outcome, computed inside
/// the modifier's nonisolated closure so the non-Sendable `TranslationSession`
/// never crosses into the `@MainActor` ``TranslationPackDownloadCoordinator``
/// (Swift 6 strict concurrency `complete`). Mirrors the proven `TranslationError`
/// catch mapping in `TranslationService.swift`.
enum TranslationPackDownloadOutcome: Sendable {
    case prepared
    case pairingUnsupported
    case cancelled
    case engineFailure(String)
}


/// `Sendable` adapter making the `@MainActor` coordinator satisfy the frozen
/// `TranslationPackSystemDownloadPort`. Holds only the coordinator (a
/// `@MainActor` class, hence `Sendable`); the `await` hops to the main actor.
struct SwiftUITranslationPackDownloadPort: TranslationPackSystemDownloadPort {
    let coordinator: TranslationPackDownloadCoordinator

    func requestSystemDownload(
        from source: Locale.Language,
        into target: Locale.Language
    ) async throws(TranslationServiceError) {
        try await coordinator.requestDownload(from: source, into: target)
    }
}
