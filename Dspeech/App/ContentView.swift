import SwiftUI

struct ContentView: View {
    @State private var liveViewModel: LiveTranscriptionViewModel
    @State private var privacy: PrivacySettings
    @State private var showTranslation: Bool = true
    @State private var showSettings: Bool = false
    @State private var showFirstRun: Bool
    @State private var firstRunViewModel: FirstRunViewModel?
    @AppStorage("dspeech.translation.targetLanguageCode") private var targetLanguageCode = "ru"

    private let audioService: any AudioInputService
    private let translationService: any TranslationService
    private let firstRunCoordinator: any FirstRunCoordinator
    private let permissionRequester: any OnboardingPermissionRequesting

    init(
        liveViewModel: LiveTranscriptionViewModel = ContentView.makeDefaultLiveViewModel(),
        privacy: PrivacySettings = PrivacySettings(),
        audioService: any AudioInputService = AppleAudioInputService(),
        translationService: any TranslationService = LocalTranslationService(backend: AppleTranslationService()),
        firstRunCoordinator: any FirstRunCoordinator = DefaultFirstRunCoordinator(),
        permissionRequester: any OnboardingPermissionRequesting = SystemOnboardingPermissionRequester()
    ) {
        _liveViewModel = State(initialValue: liveViewModel)
        _privacy = State(initialValue: privacy)
        self.audioService = audioService
        self.translationService = translationService
        self.firstRunCoordinator = firstRunCoordinator
        self.permissionRequester = permissionRequester
        // why: deciding first-run in .onAppear races SwiftUI's first
        // presentation transaction and the cover is silently dropped at
        // launch (XCUITest sees the transcript surface directly). Arming
        // the cover from synchronously-resolved init state makes
        // presentation deterministic.
        _showFirstRun = State(initialValue: firstRunCoordinator.currentState() != .completed)
    }

    static func makeDefaultLiveViewModel() -> LiveTranscriptionViewModel {
        LiveTranscriptionViewModel(engine: AppleSpeechLiveTranscriptionEngine())
    }

    private var emptyStateText: String {
        switch liveViewModel.status {
        case .idle, .stopped:
            return "Нажмите «Старт» и говорите — расшифровка появится здесь.\nЛокальная обработка, аудио не покидает устройство."
        case .requestingPermission:
            return "Запрос доступа к микрофону и распознаванию речи…"
        case .ready, .listening:
            return "Слушаю…"
        case .failed(let message):
            return "Ошибка: \(message)"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height

            ZStack {
                LinearGradient(
                    colors: [Color.black, Color(red: 0.03, green: 0.06, blue: 0.10)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: isLandscape ? 8 : 12) {
                    controlBar(isLandscape: isLandscape)
                    transcriptArea(isLandscape: isLandscape)
                    bottomBar(isLandscape: isLandscape)
                }
                .padding(.horizontal, isLandscape ? 16 : 18)
                .padding(.top, isLandscape ? 6 : 10)
                .padding(.bottom, isLandscape ? 8 : 14)
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(
                privacy: privacy,
                audioService: audioService,
                translationService: translationService,
                targetLanguageCode: $targetLanguageCode,
                onSelectTargetLanguage: { language in applySelectedTargetLanguage(language) }
            )
        }
        .fullScreenCover(isPresented: $showFirstRun) {
            Group {
                if let firstRunViewModel {
                    FirstRunView(viewModel: firstRunViewModel)
                } else {
                    Color.black.ignoresSafeArea()
                }
            }
            .task { ensureFirstRunViewModel() }
        }
    }

    private func ensureFirstRunViewModel() {
        guard firstRunViewModel == nil else { return }
        firstRunViewModel = FirstRunViewModel(
            coordinator: firstRunCoordinator,
            privacy: privacy,
            permissionRequester: permissionRequester,
            initialTargetLanguageCode: targetLanguageCode,
            onSelectTargetLanguage: { language in applySelectedTargetLanguage(language) },
            onFinished: { showFirstRun = false }
        )
    }

    private func applySelectedTargetLanguage(_ language: Locale.Language) {
        guard let match = dspeechGlossLanguages.first(where: {
            Locale.Language(identifier: $0.code).languageCode == language.languageCode
        }) else { return }
        targetLanguageCode = match.code
    }

    @ViewBuilder
    private func transcriptArea(isLandscape: Bool) -> some View {
        if liveViewModel.segments.isEmpty && liveViewModel.partialText.isEmpty {
            VStack {
                Spacer()
                Text(emptyStateText)
                    .font(.system(size: isLandscape ? 18 : 20, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .accessibilityIdentifier("transcript-empty-state")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: isLandscape ? 10 : 12) {
                    ForEach(liveViewModel.segments) { segment in
                        TranscriptSegmentCard(
                            segment: segment,
                            showTranslation: showTranslation,
                            isLandscape: isLandscape
                        )
                    }
                    if !liveViewModel.partialText.isEmpty {
                        PartialTranscriptCard(text: liveViewModel.partialText, isLandscape: isLandscape)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func bottomBar(isLandscape: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { await toggleListening() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: liveViewModel.isListening ? "stop.fill" : "mic.fill")
                    Text(liveViewModel.isListening ? "Стоп" : "Старт")
                        .font(.headline)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .frame(minWidth: isLandscape ? 110 : 130)
                .background(
                    Capsule().fill(liveViewModel.isListening ? Color.red.opacity(0.85) : Color.cyan.opacity(0.85))
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(liveViewModel.isListening ? "stop-button" : "start-button")

            if !liveViewModel.segments.isEmpty {
                Button("Очистить") {
                    liveViewModel.reset()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityIdentifier("clear-button")
            }

            Spacer()

            if let error = liveViewModel.lastErrorMessage {
                Text(error)
                    .font(.caption.monospaced())
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .accessibilityIdentifier("error-banner")
            }
        }
    }

    private func toggleListening() async {
        if liveViewModel.isListening {
            liveViewModel.stop()
        } else {
            await liveViewModel.start()
        }
    }

    private func controlBar(isLandscape: Bool) -> some View {
        HStack(spacing: 14) {
            Text("Dspeech")
                .font(.system(size: isLandscape ? 22 : 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .accessibilityIdentifier("app-title")

            PrivacyBadge(mode: privacy.mode, isLandscape: isLandscape)

            Spacer()

            settingsButton(isLandscape: isLandscape)

            Toggle(isOn: $showTranslation) {
                Text("Перевод")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .toggleStyle(.switch)
            .tint(.cyan)
            .fixedSize()
            .accessibilityIdentifier("translation-toggle")
        }
    }

    private func settingsButton(isLandscape: Bool) -> some View {
        let diameter: CGFloat = isLandscape ? 32 : 36
        return Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: isLandscape ? 15 : 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: diameter, height: diameter)
                .background(
                    Circle()
                        .fill(.white.opacity(0.12))
                )
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityIdentifier("settings-button")
        .accessibilityLabel("Настройки")
    }
}

struct PrivacyBadge: View {
    let mode: PrivacyMode
    let isLandscape: Bool

    var body: some View {
        let isLocal = mode == .localOnly
        let tint: Color = isLocal ? .green : .orange
        Text(mode.badgeText)
            .font(.system(size: isLandscape ? 10 : 11, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.16), in: Capsule())
            .overlay(
                Capsule().stroke(tint.opacity(0.45), lineWidth: 1)
            )
            .accessibilityIdentifier("privacy-badge")
            .accessibilityLabel(isLocal ? "Локальная обработка" : "Облачная обработка (с согласия)")
    }
}

private struct PartialTranscriptCard: View {
    let text: String
    let isLandscape: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: isLandscape ? 16 : 18, weight: .semibold))
                .foregroundStyle(.cyan.opacity(0.9))
                .padding(.top, 4)
            Text(text)
                .font(.system(size: isLandscape ? 22 : 26, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .italic()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.cyan.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.cyan.opacity(0.30), lineWidth: 1)
        }
        .accessibilityIdentifier("partial-transcript")
    }
}

private struct TranscriptSegmentCard: View {
    let segment: TranscriptSegment
    let showTranslation: Bool
    let isLandscape: Bool

    private var hasTranslation: Bool {
        showTranslation && segment.translatedText != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            badgeRow
            body(hasTranslation: hasTranslation)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .white.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var badgeRow: some View {
        HStack(spacing: 8) {
            Text(segment.sourceLanguageCode.uppercased())
                .font(.caption.monospaced().weight(.bold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.white.opacity(0.12), in: Capsule())

            if segment.requiresVerification {
                Text("VERIFY")
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.yellow.opacity(0.16), in: Capsule())
            }

            Spacer()

            Text(segment.confidence.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    @ViewBuilder
    private func body(hasTranslation: Bool) -> some View {
        if hasTranslation, let translated = segment.translatedText {
            if isLandscape {
                HStack(alignment: .top, spacing: 14) {
                    Text(segment.text)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle()
                        .fill(.white.opacity(0.15))
                        .frame(width: 1)
                    Text(translated)
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .foregroundStyle(.cyan.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .minimumScaleFactor(0.55)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(segment.text)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Rectangle()
                        .fill(.white.opacity(0.15))
                        .frame(height: 1)
                    Text(translated)
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .foregroundStyle(.cyan.opacity(0.85))
                }
                .minimumScaleFactor(0.6)
            }
        } else {
            Text(segment.text)
                .font(.system(size: isLandscape ? 26 : 30, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .minimumScaleFactor(0.6)
        }
    }
}

#Preview("Portrait") {
    ContentView()
}

#Preview("Landscape", traits: .landscapeLeft) {
    ContentView()
}
