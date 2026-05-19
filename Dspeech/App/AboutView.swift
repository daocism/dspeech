import SwiftUI
import Foundation

struct AboutView: View {
    var body: some View {
        List {
            Section {
                LabeledContent("Приложение", value: "Dspeech")
                    .accessibilityIdentifier("about-app-name")
                LabeledContent("Версия", value: Self.versionString)
                    .accessibilityIdentifier("about-version")
            }

            Section {
                HStack {
                    Spacer()
                    LocalOnlyBadge()
                        .accessibilityIdentifier("about-privacy-badge")
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } footer: {
                Text("В режиме LOCAL аудио, транскрипты и метаданные не покидают iPhone. Облако включается только явно и видно по бейджу CLOUD на главном экране (ADR 0002).")
            }

            Section("Распознавание и перевод") {
                attributionRow(
                    title: "Распознавание речи",
                    detail: "Apple Speech (фреймворк Speech, iOS). Распознавание выполняется на устройстве."
                )
                .accessibilityIdentifier("about-attribution-apple-speech")
                attributionRow(
                    title: "Перевод",
                    detail: "Apple Translation (фреймворк Translation, iOS). Перевод выполняется на устройстве; языковые пакеты загружает системный механизм Apple."
                )
                .accessibilityIdentifier("about-attribution-translation")
                attributionRow(
                    title: "Аудио",
                    detail: "AVFoundation / AVAudioSession (Apple)."
                )
            }

            Section("Лицензии и компоненты") {
                Text("Dspeech использует только системные фреймворки Apple: SwiftUI, Speech, Translation, AVFoundation, Observation, Foundation. Сторонние open‑source компоненты в сборку не включены.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Системные фреймворки и SDK предоставляются Apple Inc. на условиях Apple SDK Agreement. Товарные знаки Apple, iPhone, Siri и связанные технологии принадлежат Apple Inc.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("about-licenses")

            Section {
                Text("Dspeech — приёмное приложение для расшифровки кабинной/диспетчерской речи. Не предназначено для передачи в эфир и не является сертифицированным авиационным оборудованием.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("О приложении")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("about-view")
    }

    private func attributionRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.body.weight(.medium))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "—"
        let build = (info?["CFBundleVersion"] as? String) ?? "—"
        return "\(short) (\(build))"
    }
}

struct LocalOnlyBadge: View {
    var body: some View {
        Text("ЛОКАЛЬНО НА УСТРОЙСТВЕ")
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(.green)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.green.opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(.green.opacity(0.45), lineWidth: 1))
            .accessibilityLabel("Локальная обработка на устройстве")
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
