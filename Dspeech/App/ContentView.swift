import SwiftUI

struct ContentView: View {
    @State private var coordinator: CaptureCoordinator
    @State private var voiceFilter: VoiceFilterPipeline
    @State private var privacy = PrivacySettings()
    @State private var showTranslation: Bool = true
    @State private var showSettings: Bool = false

    init(
        engine: (any LiveTranscriptionEngine)? = nil,
        voiceFilter: VoiceFilterPipeline? = nil,
        routing: AudioSessionRouting = LiveAudioSessionRouting()
    ) {
        let filter = voiceFilter ?? VoiceFilterPipeline(identifier: UnavailableLocalSpeakerIdentifier())
        let resolvedEngine = engine ?? AppleSpeechLiveTranscriptionEngine(
            bufferGate: VoiceFilterSpeechAudioBufferGate(pipeline: filter)
        )
        let live = LiveTranscriptionViewModel(engine: resolvedEngine, voiceFilter: filter)
        let monitor = RouteHealthMonitor(routing: routing)
        _voiceFilter = State(initialValue: filter)
        _coordinator = State(initialValue: CaptureCoordinator(
            live: live,
            routeMonitor: monitor,
            routeChanges: routing.routeChanges
        ))
    }

    private var liveViewModel: LiveTranscriptionViewModel { coordinator.live }

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
                    routeBanner(isLandscape: isLandscape)
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
            SettingsView(privacy: privacy, voiceFilter: voiceFilter)
        }
        .onAppear { coordinator.beginObservingRouteChanges() }
        .onDisappear { coordinator.endObservingRouteChanges() }
    }

    @ViewBuilder
    private func routeBanner(isLandscape: Bool) -> some View {
        if let message = coordinator.routeBanner ?? coordinator.startBlockedMessage {
            HStack(spacing: 8) {
                Image(systemName: coordinator.canStart ? "exclamationmark.triangle.fill" : "mic.slash.fill")
                    .font(.system(size: isLandscape ? 13 : 14, weight: .semibold))
                Text(message)
                    .font(.system(size: isLandscape ? 13 : 14, weight: .medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(coordinator.canStart ? Color.orange : Color.red)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (coordinator.canStart ? Color.orange : Color.red).opacity(0.14),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke((coordinator.canStart ? Color.orange : Color.red).opacity(0.4), lineWidth: 1)
            }
            .accessibilityIdentifier("route-banner")
        }
    }

    @ViewBuilder
    private func transcriptArea(isLandscape: Bool) -> some View {
        let displayedSegments = liveViewModel.visibleSegments
        if displayedSegments.isEmpty && liveViewModel.partialText.isEmpty {
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
                    ForEach(displayedSegments) { segment in
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
            let startDisabled = !liveViewModel.isListening && !coordinator.canStart
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
                .opacity(startDisabled ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(startDisabled)
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
        await coordinator.toggle()
    }

    private func controlBar(isLandscape: Bool) -> some View {
        HStack(spacing: 14) {
            Text("Dspeech")
                .font(.system(size: isLandscape ? 22 : 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .accessibilityIdentifier("app-title")

            PrivacyBadge(mode: privacy.mode, isLandscape: isLandscape)

            RouteHealthChip(health: coordinator.routeMonitor.health, isLandscape: isLandscape)

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

struct RouteHealthChip: View {
    let health: RouteHealth
    let isLandscape: Bool

    private var tint: Color {
        switch health {
        case .suitableExternal: return .green
        case .cautionBuiltIn: return .orange
        case .unknownExternal, .unsuitableOutputOnly: return .yellow
        case .noInput: return .red
        }
    }

    private var icon: String {
        switch health {
        case .suitableExternal: return "cable.connector"
        case .cautionBuiltIn: return "iphone"
        case .unknownExternal: return "questionmark.circle"
        case .unsuitableOutputOnly: return "speaker.wave.2"
        case .noInput: return "mic.slash"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: isLandscape ? 9 : 10, weight: .bold))
            Text(health.shortLabel)
                .font(.system(size: isLandscape ? 10 : 11, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.16), in: Capsule())
        .overlay(
            Capsule().stroke(tint.opacity(0.45), lineWidth: 1)
        )
        .accessibilityIdentifier("route-health-chip")
        .accessibilityLabel("Источник захвата: \(health.displayLabel)")
    }
}

struct SettingsView: View {
    @Bindable var privacy: PrivacySettings
    var voiceFilter: VoiceFilterPipeline?
    @Environment(\.dismiss) private var dismiss

    init(privacy: PrivacySettings, voiceFilter: VoiceFilterPipeline? = nil) {
        self.privacy = privacy
        self.voiceFilter = voiceFilter
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

                if let voiceFilter {
                    VoiceFilterSettingsSection(pipeline: voiceFilter)
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

struct VoiceFilterSettingsSection: View {
    let pipeline: VoiceFilterPipeline

    @State private var enabled: Bool
    @State private var callsignDraft: String
    @State private var modelPackState: ModelPackState

    init(pipeline: VoiceFilterPipeline) {
        self.pipeline = pipeline
        _enabled = State(initialValue: pipeline.enabled)
        _callsignDraft = State(initialValue: pipeline.callSign?.raw ?? "")
        _modelPackState = State(initialValue: pipeline.modelPackState)
    }

    private var identifierAvailable: Bool {
        if case .ready = pipeline.capability { return true }
        return false
    }

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Фильтр диспетчер/пилот")
                        .font(.body.weight(.medium))
                    Text(enabled
                         ? "Скрывать переговоры пилотов и нерелевантные обращения диспетчера."
                         : "Все сегменты ATC отображаются.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("voicefilter-enabled-toggle")
            .onChange(of: enabled) { _, newValue in
                pipeline.setEnabled(newValue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Позывной воздушного судна")
                    .font(.body.weight(.medium))
                TextField("N123AB / RA-89077 / SBI247", text: $callsignDraft)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                    .accessibilityIdentifier("voicefilter-callsign-field")
                Text(callsignDraft.isEmpty
                     ? "Без позывного фильтр пропускает все сегменты не-пилотов."
                     : "Сегменты без совпадения по позывному будут скрываться, пока окно продолжения активно.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: callsignDraft) { _, newValue in
                pipeline.setCallSign(newValue.isEmpty ? nil : newValue)
            }

            modelPackContent
        } header: {
            Text("Голосовой фильтр ATC")
        } footer: {
            Text("Распознавание выполняется только на устройстве. Аудио и образцы голоса не покидают iPhone. Подробности — ADR 0007 и ADR 0008.")
        }
    }

    @ViewBuilder
    private var modelPackContent: some View {
        switch modelPackState {
        case .absent:
            absentContent
        case .acquiring(let acquisition):
            acquiringContent(acquisition)
        case .installed(let pack):
            installedContent(pack)
        case .failed(let failure):
            failedContent(failure)
        case .disabled(let pack):
            disabledContent(pack)
        }
    }

    private func transition(to state: ModelPackState) {
        pipeline.setModelPackState(state)
        modelPackState = state
    }

    private var absentContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Модель не установлена", systemImage: "arrow.down.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Голосовой фильтр пилотов работает только после установки локального пакета модели. Загрузка — разовая, явная, по вашему запросу; аудио при этом не покидает устройство.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Скачать пакет голосового фильтра (≈ размер уточняется)") {}
                .buttonStyle(.bordered)
                .disabled(true)
                .accessibilityIdentifier("voicefilter-modelpack-download-cta")
            Text("Источник модели и точный размер появятся, когда канал загрузки будет подключён. Пока загрузчик недоступен в этой сборке.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("voicefilter-modelpack-absent")
    }

    private func acquiringContent(_ acquisition: ModelPackAcquisition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(acquisition.phase == .downloading ? "Загрузка модели…" : "Установка модели…")
                .font(.subheadline.weight(.semibold))
            ProgressView(value: acquisition.fractionComplete)
                .accessibilityIdentifier("voicefilter-modelpack-progress")
            if let received = acquisition.bytesReceived, let total = acquisition.totalBytes {
                Text("\(byteString(received)) из \(byteString(total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("Отменить") {
                transition(to: .absent)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("voicefilter-modelpack-cancel")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("voicefilter-modelpack-acquiring")
    }

    private func installedContent(_ pack: InstalledModelPack) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Модель установлена и проверена", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
            Text("Пакет «\(pack.identifier)» · \(pack.embeddingDimension)-мерные эмбеддинги · \(byteString(pack.sizeBytes)). Распознавание выполняется офлайн.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !identifierAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Слот пилота недоступен", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("Пакет установлен, но локальный распознаватель не подключён в этой сборке, поэтому запись голоса отключена.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("voicefilter-capability-banner")
            }

            ForEach(PilotVoiceProfile.Slot.allCases, id: \.rawValue) { slot in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(slot == .primary ? "Pilot 1 (Captain)" : "Pilot 2 (First Officer)")
                            .font(.body.weight(.medium))
                        Text(identifierAvailable
                             ? "Запишите образец голоса для распознавания."
                             : "Запись станет доступна, когда распознаватель будет подключён.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Записать голос") {}
                        .disabled(!identifierAvailable)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(
                            slot == .primary
                            ? "voicefilter-enroll-pilot1"
                            : "voicefilter-enroll-pilot2"
                        )
                }
            }

            Button("Удалить пакет") {
                transition(to: .absent)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .accessibilityIdentifier("voicefilter-modelpack-delete")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("voicefilter-modelpack-installed")
    }

    private func failedContent(_ failure: ModelPackFailure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Не удалось установить модель", systemImage: "xmark.octagon.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            Text(failure.userSafeReason)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if failure.isRetryable {
                Button("Повторить загрузку") {}
                    .buttonStyle(.bordered)
                    .disabled(true)
                    .accessibilityIdentifier("voicefilter-modelpack-retry")
            }
            Button("Продолжить без голосового фильтра") {
                transition(to: .absent)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("voicefilter-modelpack-continue-without")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("voicefilter-modelpack-failed")
    }

    private func disabledContent(_ pack: InstalledModelPack) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Пакет установлен, фильтр выключен", systemImage: "pause.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Модель «\(pack.identifier)» остаётся на устройстве. Включите фильтр выше или удалите пакет, чтобы освободить место.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Включить голосовой фильтр") {
                transition(to: .installed(pack))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("voicefilter-modelpack-enable")
            Button("Удалить пакет (\(byteString(pack.sizeBytes)))") {
                transition(to: .absent)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .accessibilityIdentifier("voicefilter-modelpack-delete")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("voicefilter-modelpack-disabled")
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
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
