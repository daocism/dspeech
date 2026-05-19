import SwiftUI
import Foundation

/// Composition-ready Settings sections. The shipped Settings UI is the `Form`
/// in `ContentView.swift`'s `SettingsView`; these are standalone `Section`s the
/// integrator (W5) drops in, so `SettingsView` itself is not touched. Each
/// consumes only the frozen Core protocols via DI — no W2/W3 concrete types.

// MARK: - Audio source (PRD F5)

struct AudioSourceSettingsSection: View {
    let service: any AudioInputService

    @State private var inputs: [AudioInputDescriptor] = []
    @State private var currentInputID: String?
    @State private var level: Float = 0
    @State private var errorText: String?

    var body: some View {
        Section {
            if inputs.isEmpty {
                Text("Входы не найдены. Подключите гарнитуру или USB‑C интерфейс.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(inputs) { input in
                    Button {
                        select(input)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(input.displayName)
                                    .foregroundStyle(.primary)
                                Text(kindLabel(input.kind))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if input.id == currentInputID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.cyan)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("audio-source-row-\(input.id)")
                }
            }

            levelMeter

            if let errorText {
                Text(errorText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("audio-source-error")
            }
        } header: {
            Text("Источник звука")
        } footer: {
            Text("Встроенный микрофон — только для пробы. Для точности в кабине используйте проводной вход. Выбор сохраняется для этого устройства.")
        }
        .accessibilityIdentifier("audio-source-picker")
        .onAppear(perform: reload)
        .task { await observeLevels() }
        .task { await observeRouteChanges() }
    }

    private var levelMeter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Уровень сигнала")
                .font(.footnote)
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.12))
                    Capsule()
                        .fill(level < 0.15 ? Color.orange : Color.cyan)
                        .frame(width: geometry.size.width * CGFloat(min(max(level, 0), 1)))
                }
            }
            .frame(height: 10)
            .accessibilityIdentifier("audio-level-meter")
            .accessibilityValue(Text(level.formatted(.percent.precision(.fractionLength(0)))))
            if level < 0.15 {
                Text("Низкий уровень — проверьте подключение и громкость источника.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private func reload() {
        do {
            inputs = try service.availableInputs()
            currentInputID = service.currentInput()?.id
            errorText = nil
        } catch {
            inputs = []
            errorText = describe(error)
        }
    }

    private func select(_ input: AudioInputDescriptor) {
        do {
            try service.select(input)
            currentInputID = input.id
            errorText = nil
        } catch {
            errorText = describe(error)
        }
    }

    private func observeLevels() async {
        do {
            for try await sample in service.levels() {
                level = sample.normalized
            }
        } catch {
            level = 0
            errorText = "Метр уровня недоступен."
        }
    }

    private func observeRouteChanges() async {
        for await change in service.routeChanges() {
            reload()
            if let active = change.activeInput {
                currentInputID = active.id
            }
        }
    }

    private func kindLabel(_ kind: AudioInputKind) -> String {
        switch kind {
        case .builtInMicrophone: return "Встроенный микрофон (проба)"
        case .wired: return "Проводной вход (USB‑C / TRRS)"
        case .bluetooth: return "Bluetooth (хуже, с задержкой)"
        case .other: return "Другой маршрут"
        }
    }

    private func describe(_ error: AudioInputServiceError) -> String {
        switch error {
        case .audioSessionUnavailable:
            return "Аудиосессия недоступна."
        case .noInputsAvailable:
            return "Нет доступных входов."
        case .inputNotSelectable:
            return "Этот вход сейчас недоступен."
        case .activationFailed:
            return "Не удалось активировать аудиосессию."
        case .meteringUnavailable:
            return "Метр уровня недоступен."
        }
    }
}

// MARK: - Translation (PRD F3 / §2)

struct TranslationSettingsSection: View {
    let service: any TranslationService
    let preparer: any TranslationLanguagePackPreparer
    let selectedLanguageCode: String
    let onSelectTargetLanguage: (Locale.Language) -> Void

    /// English is the primary ATC source language (PRD F1); the en→target pack
    /// is the one the user will need first, so availability/download is keyed on
    /// it. Per-segment source is ASR-detected at runtime, not here.
    private let sourceLanguage = Locale.Language(identifier: "en")

    @State private var languageCode: String = "ru"
    @State private var status: TranslationLanguageStatus?
    @State private var isPreparing = false
    @State private var errorText: String?

    var body: some View {
        Section {
            Picker("Целевой язык", selection: $languageCode) {
                ForEach(dspeechGlossLanguages) { language in
                    Text(language.nativeName).tag(language.code)
                }
            }
            .accessibilityIdentifier("translation-target-language-picker")

            statusRow

            if status == .downloadable {
                Button {
                    Task { await downloadPack() }
                } label: {
                    HStack {
                        if isPreparing {
                            ProgressView()
                        }
                        Text(isPreparing ? "Загрузка пакета…" : "Скачать языковой пакет")
                    }
                }
                .disabled(isPreparing)
                .accessibilityIdentifier("translation-download-cta")
            }

            if let errorText {
                Text(errorText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("translation-error")
            }
        } header: {
            Text("Перевод")
        } footer: {
            Text("Перевод выполняется на устройстве. Недостающий пакет скачивается системным механизмом Apple по явному действию — без облака и без скрытой передачи.")
        }
        .accessibilityIdentifier("translation-section")
        .onAppear { languageCode = selectedLanguageCode }
        .task(id: languageCode) { await refreshStatus() }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch status {
        case .installed:
            label("Пакет установлен — работает офлайн", systemImage: "checkmark.seal.fill", tint: .green)
        case .downloadable:
            label("Пакет не установлен", systemImage: "arrow.down.circle", tint: .cyan)
        case .unsupported:
            label("Эта пара языков недоступна", systemImage: "xmark.octagon", tint: .orange)
        case nil:
            label("Проверка доступности…", systemImage: "hourglass", tint: .secondary)
        }
    }

    private func label(_ text: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(text).font(.footnote)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .accessibilityIdentifier("translation-status")
    }

    private func currentTarget() -> Locale.Language {
        Locale.Language(identifier: languageCode)
    }

    private func refreshStatus() async {
        onSelectTargetLanguage(currentTarget())
        status = await service.availability(
            translatingFrom: sourceLanguage,
            into: currentTarget()
        )
    }

    private func downloadPack() async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            try await preparer.prepareLanguages(from: sourceLanguage, into: currentTarget())
            errorText = nil
            status = await service.availability(
                translatingFrom: sourceLanguage,
                into: currentTarget()
            )
        } catch {
            errorText = describe(error)
        }
    }

    private func describe(_ error: TranslationServiceError) -> String {
        switch error {
        case .emptyInput:
            return "Нечего переводить."
        case .sourceLanguageUnsupported:
            return "Исходный язык не поддерживается."
        case .targetLanguageUnsupported:
            return "Целевой язык не поддерживается."
        case .languagePairingUnsupported:
            return "Эта пара языков не поддерживается."
        case .languagePackNotInstalled:
            return "Пакет не установлен. Скачайте его, чтобы переводить офлайн."
        case .sessionCancelled:
            return "Загрузка отменена."
        case .engineFailure:
            return "Не удалось подготовить перевод."
        }
    }
}

// MARK: - About

struct AboutSettingsSection: View {
    var body: some View {
        Section {
            NavigationLink {
                AboutView()
            } label: {
                LabeledContent("О приложении", value: AboutView.versionString)
            }
            .accessibilityIdentifier("about-nav-link")
        }
        .accessibilityIdentifier("about-section")
    }
}
