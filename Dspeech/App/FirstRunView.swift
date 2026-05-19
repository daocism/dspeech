import SwiftUI
@preconcurrency import Speech
@preconcurrency import AVFoundation
import Foundation
import Observation

/// One-shot request for the two permissions Dspeech needs to be usable straight
/// out of onboarding. Real OS prompts — no fake/stub (repo `CLAUDE.md` rule 2).
protocol OnboardingPermissionRequesting: Sendable {
    /// Requests speech-recognition then microphone authorization. Returns
    /// whether *both* were granted; onboarding completes regardless so the user
    /// is never trapped (denied state is surfaced later by the ASR engine).
    func requestSpeechAndMicrophone() async -> Bool
}

struct SystemOnboardingPermissionRequester: OnboardingPermissionRequesting {
    func requestSpeechAndMicrophone() async -> Bool {
        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        let micAllowed = await AVAudioApplication.requestRecordPermission()
        return speechAuthorized && micAllowed
    }
}

/// A target gloss language offered at first run / in Settings. The user's own
/// reading-language choice — not a region/availability or pricing list, so the
/// repo CIS-region rule (`CLAUDE.md` hard rule 8) does not apply here.
struct GlossLanguage: Identifiable, Hashable, Sendable {
    let code: String
    let nativeName: String

    var id: String { code }
    var language: Locale.Language { Locale.Language(identifier: code) }
}

let dspeechGlossLanguages: [GlossLanguage] = [
    GlossLanguage(code: "ru", nativeName: "Русский"),
    GlossLanguage(code: "uk", nativeName: "Українська"),
    GlossLanguage(code: "en", nativeName: "English"),
    GlossLanguage(code: "es", nativeName: "Español"),
    GlossLanguage(code: "fr", nativeName: "Français"),
    GlossLanguage(code: "de", nativeName: "Deutsch"),
    GlossLanguage(code: "pt-BR", nativeName: "Português"),
    GlossLanguage(code: "zh", nativeName: "中文")
]

@MainActor
@Observable
final class FirstRunViewModel {
    private let coordinator: any FirstRunCoordinator
    private let privacy: PrivacySettings
    private let permissionRequester: any OnboardingPermissionRequesting
    private let onSelectTargetLanguage: @MainActor (Locale.Language) -> Void
    private let onFinished: @MainActor () -> Void

    private(set) var state: FirstRunState
    private(set) var isFinishing = false
    private(set) var lastError: String?
    var selectedLanguageCode: String

    init(
        coordinator: any FirstRunCoordinator,
        privacy: PrivacySettings,
        permissionRequester: any OnboardingPermissionRequesting = SystemOnboardingPermissionRequester(),
        initialTargetLanguageCode: String = "ru",
        onSelectTargetLanguage: @escaping @MainActor (Locale.Language) -> Void = { _ in },
        onFinished: @escaping @MainActor () -> Void = {}
    ) {
        self.coordinator = coordinator
        self.privacy = privacy
        self.permissionRequester = permissionRequester
        self.onSelectTargetLanguage = onSelectTargetLanguage
        self.onFinished = onFinished
        self.selectedLanguageCode = initialTargetLanguageCode
        self.state = coordinator.currentState()
    }

    var card: FirstRunCard? {
        if case let .showing(card) = state { return card }
        return nil
    }

    var cardNumber: Int {
        guard let card, let index = FirstRunCard.allCases.firstIndex(of: card) else { return 0 }
        return index + 1
    }

    var cardCount: Int { FirstRunCard.allCases.count }

    var isLastCard: Bool { card == FirstRunCard.allCases.last }

    func selectLanguage(code: String) {
        selectedLanguageCode = code
        onSelectTargetLanguage(Locale.Language(identifier: code))
    }

    func advance() {
        do {
            state = try coordinator.advance()
            settleIfCompleted()
        } catch {
            lastError = Self.describe(error)
        }
    }

    func skip() {
        do {
            try coordinator.skip()
            state = coordinator.currentState()
            settleIfCompleted()
        } catch {
            lastError = Self.describe(error)
        }
    }

    func finish() async {
        isFinishing = true
        defer { isFinishing = false }

        privacy.mode = .localOnly
        onSelectTargetLanguage(Locale.Language(identifier: selectedLanguageCode))
        _ = await permissionRequester.requestSpeechAndMicrophone()

        do {
            state = try coordinator.advance()
            settleIfCompleted()
        } catch {
            lastError = Self.describe(error)
        }
    }

    private func settleIfCompleted() {
        if state == .completed { onFinished() }
    }

    private static func describe(_ error: FirstRunCoordinatorError) -> String {
        switch error {
        case .persistenceUnavailable:
            return "Не удалось сохранить настройку. Повторите попытку."
        }
    }
}

struct FirstRunView: View {
    @State private var viewModel: FirstRunViewModel

    init(viewModel: FirstRunViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.03, green: 0.06, blue: 0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                skipBar
                Spacer(minLength: 0)
                if let card = viewModel.card {
                    cardContent(card)
                        .id(card)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                pageDots
                primaryButton
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: viewModel.cardNumber)
        .accessibilityIdentifier("first-run-view")
    }

    private var skipBar: some View {
        HStack {
            Spacer()
            Button("Пропустить") {
                viewModel.skip()
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.7))
            .disabled(viewModel.isFinishing)
            .accessibilityIdentifier("first-run-skip")
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private func cardContent(_ card: FirstRunCard) -> some View {
        VStack(spacing: 22) {
            Image(systemName: card.systemImage)
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(.cyan)
                .accessibilityHidden(true)

            Text(card.title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("first-run-card-title")

            Text(card.message)
                .font(.system(size: 19, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.isLastCard {
                languagePicker
            }

            if let error = viewModel.lastError {
                Text(error)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("first-run-error")
            }
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-run-card-\(viewModel.cardNumber)")
    }

    private var languagePicker: some View {
        VStack(spacing: 8) {
            Text("Язык перевода")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            Picker("Язык перевода", selection: languageBinding) {
                ForEach(dspeechGlossLanguages) { language in
                    Text(language.nativeName).tag(language.code)
                }
            }
            .pickerStyle(.menu)
            .tint(.cyan)
            .accessibilityIdentifier("first-run-target-language-picker")
        }
        .padding(.top, 6)
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedLanguageCode },
            set: { viewModel.selectLanguage(code: $0) }
        )
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(1...max(viewModel.cardCount, 1), id: \.self) { index in
                Circle()
                    .fill(index == viewModel.cardNumber ? Color.cyan : Color.white.opacity(0.25))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.bottom, 22)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var primaryButton: some View {
        if viewModel.isLastCard {
            Button {
                Task { await viewModel.finish() }
            } label: {
                buttonLabel(viewModel.isFinishing ? "Подготовка…" : "Начать")
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isFinishing)
            .accessibilityIdentifier("first-run-finish")
        } else {
            Button {
                viewModel.advance()
            } label: {
                buttonLabel("Далее")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("first-run-advance")
        }
    }

    private func buttonLabel(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Capsule().fill(Color.cyan))
    }
}

private extension FirstRunCard {
    var title: String {
        switch self {
        case .receiveOnly: return "Только приём"
        case .localByDefault: return "Локально по умолчанию"
        case .wireForAccuracy: return "Подключите гарнитуру"
        }
    }

    var message: String {
        switch self {
        case .receiveOnly:
            return "Dspeech не выходит в эфир и ничего не передаёт по радио. Он только слушает и расшифровывает."
        case .localByDefault:
            return "Звук остаётся на этом iPhone. Распознавание идёт на устройстве, без облака."
        case .wireForAccuracy:
            return "Для точности в кабине используйте проводной вход (USB‑C / TRRS). Встроенный микрофон — чтобы попробовать."
        }
    }

    var systemImage: String {
        switch self {
        case .receiveOnly: return "antenna.radiowaves.left.and.right"
        case .localByDefault: return "lock.iphone"
        case .wireForAccuracy: return "cable.connector"
        }
    }
}

#Preview {
    FirstRunView(
        viewModel: FirstRunViewModel(
            coordinator: DefaultFirstRunCoordinator(),
            privacy: PrivacySettings()
        )
    )
}
