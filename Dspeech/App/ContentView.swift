import SwiftUI

struct ContentView: View {
    @State private var viewModel = TranscriptDemoViewModel.demo
    @State private var privacy = PrivacySettings()
    @State private var showTranslation: Bool = true
    @State private var showSettings: Bool = false

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
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: isLandscape ? 10 : 12) {
                            ForEach(viewModel.segments) { segment in
                                TranscriptSegmentCard(
                                    segment: segment,
                                    showTranslation: showTranslation,
                                    isLandscape: isLandscape
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(.horizontal, isLandscape ? 16 : 18)
                .padding(.top, isLandscape ? 6 : 10)
                .padding(.bottom, isLandscape ? 8 : 14)
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView(privacy: privacy)
        }
    }

    private func controlBar(isLandscape: Bool) -> some View {
        HStack(spacing: 14) {
            Text("Dspeech")
                .font(.system(size: isLandscape ? 22 : 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .accessibilityIdentifier("app-title")

            PrivacyBadge(mode: privacy.processingMode, isLandscape: isLandscape)

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

struct SettingsView: View {
    @Bindable var privacy: PrivacySettings
    @Environment(\.dismiss) private var dismiss

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
                Section("Перевод") {
                    LabeledContent("Целевой язык", value: "Русский")
                    LabeledContent(
                        "Провайдер",
                        value: privacy.allowCloud ? "Облако (по согласию)" : "Локальный"
                    )
                }
                Section("О приложении") {
                    LabeledContent("Версия", value: Bundle.main.shortVersion)
                }
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
        .accessibilityIdentifier("settings-sheet")
        .preferredColorScheme(.dark)
    }
}

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
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
