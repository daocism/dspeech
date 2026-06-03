import SwiftUI
import Translation
import UIKit

struct ContentView: View {
  @State private var coordinator: CaptureCoordinator
  @State private var voiceFilter: VoiceFilterPipeline
  @State private var privacy: PrivacySettings
  @State private var recognition: RecognitionSettings
  @State private var translation: TranslationSettings
  @State private var audioSource: AudioSourceController
  @State private var showSettings: Bool = false
  @State private var onboarding: OnboardingState
  @State private var translationConfig: TranslationSession.Configuration?
  @State private var translationPreparationToken = UUID()
  @Environment(\.scenePhase) private var scenePhase

  init(
    engine: (any LiveTranscriptionEngine)? = nil,
    voiceFilter: VoiceFilterPipeline? = nil,
    routing: AudioSessionRouting = LiveAudioSessionRouting(),
    onboarding: OnboardingState? = nil
  ) {
    let privacySettings = PrivacySettings()
    let recognitionSettings = RecognitionSettings()
    let filter: VoiceFilterPipeline
    if let voiceFilter {
      filter = voiceFilter
    } else {
      let modelPackStorage = UserDefaultsModelPackStateStorage()
      let backendBuilder = FluidAudioBackendBuilder()
      filter = VoiceFilterPipeline(
        identifier: LocalSpeakerIdentifierFactory.make(
          state: modelPackStorage.loadState(),
          backendBuilder: backendBuilder
        ),
        backendBuilder: backendBuilder,
        modelPackStorage: modelPackStorage,
        voiceFilterActive: { privacySettings.voiceFilterActive }
      )
    }
    let resolvedEngine =
      engine
      ?? AppleSpeechLiveTranscriptionEngine(
        localeProvider: { recognitionSettings.localeIdentifier },
        bufferGate: VoiceFilterSpeechAudioBufferGate(pipeline: filter)
      )
    let translationSettings = TranslationSettings()
    let live = LiveTranscriptionViewModel(
      engine: resolvedEngine,
      voiceFilter: filter,
      translator: LocalTranslationService(backend: AppleTranslationService()),
      translationTarget: { translationSettings.enabled ? translationSettings.targetLanguage : nil }
    )
    let monitor = RouteHealthMonitor(routing: routing)
    _privacy = State(initialValue: privacySettings)
    _recognition = State(initialValue: recognitionSettings)
    _voiceFilter = State(initialValue: filter)
    _translation = State(initialValue: translationSettings)
    _audioSource = State(initialValue: AudioSourceController(routing: routing))
    _onboarding = State(initialValue: onboarding ?? OnboardingState())
    _coordinator = State(
      initialValue: CaptureCoordinator(
        live: live,
        routeMonitor: monitor,
        routeChanges: routing.routeChanges
      ))
  }

  private var liveViewModel: LiveTranscriptionViewModel { coordinator.live }

  private var transcriptSegmentsForDisplay: [TranscriptSegment] {
    let liveSegments = liveViewModel.visibleSegments
    // why: the demo transcript is a first-run illustration ONLY — show it solely before the
    // first Start, never over real content and never again after a real session (the
    // "press Stop and my transcript turns back into demo" bug).
    guard liveSegments.isEmpty,
      liveViewModel.partialText.isEmpty,
      !liveViewModel.hasEverStarted
    else {
      return liveSegments
    }
    return TranscriptDemoViewModel.demo.segments
  }

  private var emptyStateText: String {
    switch liveViewModel.status {
    case .idle, .stopped:
      return String(
        localized:
          "Нажмите «Старт» и говорите — расшифровка появится здесь.\nЛокальная обработка, аудио не покидает устройство."
      )
    case .requestingPermission:
      return String(localized: "Запрос доступа к микрофону и распознаванию речи…")
    case .ready, .listening:
      return String(localized: "Слушаю…")
    case .failed(let message):
      return RecognitionFailureText.userFacing(message)
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
        }
        .padding(.horizontal, isLandscape ? 16 : 18)
        .padding(.top, isLandscape ? 6 : 10)
        .padding(.bottom, isLandscape ? 8 : 14)

        // why: Start + Clear/error float over the transcript (no opaque footer strip);
        // the transcript fills the full height and scrolls its content clear of them.
        bottomLeftControls(isLandscape: isLandscape)
        startControls(isLandscape: isLandscape)
      }
    }
    .statusBarHidden(true)
    .preferredColorScheme(.dark)
    .sheet(isPresented: $showSettings) {
      SettingsView(
        privacy: privacy, recognition: recognition, translation: translation,
        audioSource: audioSource,
        translationFailure: liveViewModel.translationFailure,
        captureActive: liveViewModel.isListening,
        voiceFilter: voiceFilter)
    }
    .onAppear {
      coordinator.beginObservingRouteChanges()
      audioSource.applyPersistedPreference()
      // why: .onChange(of:) does not fire for state restored from UserDefaults, so
      // a returning user who left translation ON needs the config armed here — it
      // drives .translationTask -> prepareTranslation (the only pack-download path).
      updateTranslationConfig()
    }
    .onDisappear { coordinator.endObservingRouteChanges() }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .background {
        coordinator.stopForBackground()
      }
    }
    .fullScreenCover(isPresented: onboardingPresented) {
      OnboardingView { onboarding.complete() }
    }
    .translationTask(translationConfig) {
      @Sendable [
        live = coordinator.live,
        source = Locale.Language(identifier: recognition.localeIdentifier),
        target = translation.targetLanguage,
        token = translationPreparationToken,
      ] session in
      do {
        // why: prepareTranslation presents Apple's system download sheet for a
        // not-yet-installed pair and resolves once assets are on device; a no-op
        // if already installed. Apple owns the transport (ADR 0002). Capturing the
        // @MainActor view model (not self) keeps the non-Sendable session inside
        // this nonisolated closure — no cross-actor send.
        try await session.prepareTranslation()
        await live.retranslateAll()
      } catch {
        await live.recordTranslationPreparationFailure(
          .preparation(error, source: source, target: target),
          token: token)
      }
    }
    .onChange(of: translation.enabled) { _, enabled in
      if enabled {
        // why: arming the config fires .translationTask, which retranslates after
        // prepareTranslation — a synchronous retranslateAll here would be a second,
        // redundant batch and flicker every gloss (clear -> refill).
        updateTranslationConfig()
      } else {
        translationConfig = nil
        coordinator.live.clearTranslations()
      }
    }
    .onChange(of: translation.targetCode) { _, _ in
      guard translation.enabled else { return }
      updateTranslationConfig()
    }
    .onChange(of: recognition.localeIdentifier) { _, _ in
      if translation.enabled { updateTranslationConfig() }
    }
  }

  private var onboardingPresented: Binding<Bool> {
    Binding(get: { !onboarding.hasCompletedOnboarding }, set: { _ in })
  }

  private func updateTranslationConfig() {
    guard translation.enabled else {
      translationConfig = nil
      coordinator.live.clearTranslations()
      return
    }
    let source = Locale.Language(identifier: recognition.localeIdentifier)
    translationPreparationToken = coordinator.live.beginTranslationPreparation()
    translationConfig = TranslationSession.Configuration(
      source: source, target: translation.targetLanguage)
  }

  private func glossText(for segment: TranscriptSegment) -> String? {
    // why: only ever surface a real engine-produced translation — never the demo
    // fixture's canned translatedText, which would be a fake-AI gloss (CLAUDE.md #2)
    // and would render instantly offline with no language-pack download.
    guard translation.enabled, segment.source != .demo else { return nil }
    return liveViewModel.translations[segment.id]
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
    let displayedSegments = transcriptSegmentsForDisplay
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
              translatedText: glossText(for: segment),
              isLandscape: isLandscape
            )
          }
          if !liveViewModel.partialText.isEmpty {
            PartialTranscriptCard(text: liveViewModel.partialText, isLandscape: isLandscape)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // why: clear the floating Start button so the last segment can scroll above it.
        .padding(.bottom, 84)
      }
      .scrollIndicators(.hidden)
    }
  }

  // why: launch-time hints show only in the pristine idle state (before the first
  // Start), so they grab attention once and never nag after the user has used the app.
  private var showHints: Bool { liveViewModel.status == .idle }

  private func startControls(isLandscape: Bool) -> some View {
    HStack(spacing: 12) {
      if showHints {
        HintBubble(text: "Нажмите, чтобы начать распознавание")
      }
      StartButton(
        isStopVisible: liveViewModel.canStopCurrentSession,
        disabled: !liveViewModel.canStopCurrentSession && !coordinator.canStart
      ) {
        Task { await toggleListening() }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    .padding(.trailing, isLandscape ? 16 : 18)
    .padding(.bottom, isLandscape ? 10 : 16)
  }

  private func bottomLeftControls(isLandscape: Bool) -> some View {
    HStack(spacing: 10) {
      if !liveViewModel.segments.isEmpty {
        Button("Очистить") {
          liveViewModel.reset()
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white.opacity(0.85))
        .accessibilityIdentifier("clear-button")
      }
      if let error = liveViewModel.lastErrorMessage {
        Text(RecognitionFailureText.userFacing(error))
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(3)
          .accessibilityIdentifier("error-banner")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    .padding(.leading, isLandscape ? 16 : 18)
    .padding(.bottom, isLandscape ? 16 : 24)
  }

  private func toggleListening() async {
    await coordinator.toggle()
  }

  private func controlBar(isLandscape: Bool) -> some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: isLandscape ? 6 : 10) {
        Text("Dspeech")
          .font(.system(size: isLandscape ? 22 : 28, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
          .accessibilityIdentifier("app-title")

        HStack(spacing: 8) {
          PrivacyBadge(mode: privacy.mode, isLandscape: isLandscape)
          RouteHealthChip(health: coordinator.routeMonitor.health, isLandscape: isLandscape)
        }
      }

      Spacer(minLength: 8)

      if showHints {
        HintBubble(text: "Настройки здесь")
      }
      settingsButton(isLandscape: isLandscape)
    }
  }

  private func settingsButton(isLandscape: Bool) -> some View {
    // why: sized to span the left column (title top → LOCAL badge bottom) per the
    // requested proportion.
    let diameter: CGFloat = isLandscape ? 46 : 56
    return Button {
      showSettings = true
    } label: {
      Image(systemName: "gearshape.fill")
        .font(.system(size: isLandscape ? 22 : 26, weight: .semibold))
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
    let tint: Color = .green
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
      .accessibilityLabel("Локальная обработка")
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
  @Bindable var recognition: RecognitionSettings
  @Bindable var translation: TranslationSettings
  var audioSource: AudioSourceController
  var translationFailure: TranslationFailure?
  var captureActive: Bool
  var voiceFilter: VoiceFilterPipeline?
  @Environment(\.dismiss) private var dismiss

  init(
    privacy: PrivacySettings, recognition: RecognitionSettings,
    translation: TranslationSettings,
    audioSource: AudioSourceController,
    translationFailure: TranslationFailure? = nil,
    captureActive: Bool = false,
    voiceFilter: VoiceFilterPipeline? = nil
  ) {
    self.privacy = privacy
    self.recognition = recognition
    self.translation = translation
    self.audioSource = audioSource
    self.translationFailure = translationFailure
    self.captureActive = captureActive
    self.voiceFilter = voiceFilter
  }

  // why: "" = follow the device language (default). A non-empty code writes the
  // standard AppleLanguages override, which iOS applies on the next launch — the clean
  // in-app language switch, no bundle swizzling.
  @State private var appLanguage: String =
    (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first ?? ""

  private static let appLanguages: [(code: String, name: String)] = [
    ("", String(localized: "Системный")),
    ("en", "English"), ("ru", "Русский"), ("uk", "Українська"),
    ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"),
    ("it", "Italiano"), ("pt", "Português"), ("zh-Hans", "简体中文"), ("ja", "日本語"),
  ]

  private var audioSourceBinding: Binding<String> {
    Binding(get: { audioSource.selectedUID }, set: { audioSource.select(uid: $0) })
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Toggle(isOn: $privacy.voiceFilterActive) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Активный голосовой фильтр")
                .font(.body.weight(.medium))
              Text(
                privacy.voiceFilterActive
                  ? "Пред-ASR фильтр может скрывать только уверенно распознанную речь пилота."
                  : "Пред-ASR фильтр выключен; все аудиобуферы передаются в распознавание."
              )
              .font(.footnote)
              .foregroundStyle(.secondary)
            }
          }
          .accessibilityIdentifier("voicefilter-active-toggle")
        } header: {
          Text("Приватность")
        } footer: {
          Text("Dspeech обрабатывает звук только локально. Аудио не покидает устройство.")
        }

        if let voiceFilter {
          VoiceFilterSettingsSection(pipeline: voiceFilter)
        }

        Section {
          if audioSource.hasSelectableInputs {
            Picker("Вход", selection: audioSourceBinding) {
              ForEach(audioSource.availableInputs, id: \.uid) { input in
                Text(input.portName).tag(input.uid)
              }
            }
            .accessibilityIdentifier("audio-source-picker")
          } else {
            Text(
              "Источник входа не обнаружен. Подключите проводной вход (USB-C / TRRS) или используйте встроенный микрофон."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
          }
          if let selectionError = audioSource.selectionError {
            Text(selectionError)
              .font(.footnote)
              .foregroundStyle(.orange)
              .accessibilityIdentifier("audio-source-error")
          }
          Button {
            if audioSource.isMetering {
              audioSource.stopMetering()
            } else {
              audioSource.startMetering()
            }
          } label: {
            Label(
              audioSource.isMetering ? "Остановить проверку" : "Проверить уровень входа",
              systemImage: audioSource.isMetering ? "stop.circle" : "waveform")
          }
          .disabled(captureActive)
          .accessibilityIdentifier("audio-meter-toggle")
          if audioSource.isMetering {
            HStack(spacing: 12) {
              Text("Уровень").font(.footnote).foregroundStyle(.secondary)
              InputLevelBar(level: audioSource.inputLevel).frame(height: 8)
            }
            .accessibilityIdentifier("audio-input-level")
          }
          if let inputLevelError = audioSource.inputLevelError {
            Text(inputLevelError)
              .font(.footnote)
              .foregroundStyle(.orange)
              .accessibilityIdentifier("audio-meter-error")
          }
        } header: {
          Text("Источник звука")
        } footer: {
          Text(
            "Выбор сохраняется для этого устройства. Встроенный микрофон — для проб; для кокпита подключите проводной вход."
          )
        }
        Section("Распознавание") {
          Picker("Язык распознавания", selection: $recognition.localeIdentifier) {
            ForEach(recognition.availableLocales) { locale in
              Text(locale.displayName).tag(locale.identifier)
            }
          }
          .accessibilityIdentifier("recognition-locale-picker")
          if recognition.selectedNeedsDownload {
            VStack(alignment: .leading, spacing: 6) {
              Text(
                "Язык «\(recognition.selectedDisplayName)» ещё не загружен для распознавания на устройстве."
              )
              .font(.footnote)
              .foregroundStyle(.orange)
              .accessibilityIdentifier("recognition-download-hint")
              Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                  UIApplication.shared.open(url)
                }
              } label: {
                Label("Открыть Настройки iPhone", systemImage: "gearshape")
              }
              .accessibilityIdentifier("recognition-download-language")
              Text(
                "Затем: Основные → Клавиатура → «Языки диктовки» — включите диктовку и добавьте этот язык. Модель скачается, и распознавание заработает офлайн."
              )
              .font(.footnote)
              .foregroundStyle(.secondary)
            }
          }
          LabeledContent("Модель ASR", value: "Apple Speech")
          LabeledContent("Режим", value: privacy.mode.displayName)
        }
        Section {
          Toggle("Перевод на устройстве", isOn: $translation.enabled)
            .accessibilityIdentifier("translation-enabled-toggle")
          Picker("Целевой язык", selection: $translation.targetCode) {
            ForEach(translation.availableTargets) { option in
              Text(option.displayName).tag(option.code)
            }
          }
          .accessibilityIdentifier("translation-target-picker")
          if translation.enabled, let translationFailure {
            Label(
              TranslationFailureText.userFacing(translationFailure),
              systemImage: "exclamationmark.triangle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
            .accessibilityIdentifier("translation-failure")
          }
        } header: {
          Text("Перевод")
        } footer: {
          Text(
            "Перевод выполняется на устройстве через системные языковые пакеты Apple. При первом включении iOS предложит скачать языковой пакет. Аудио и текст не покидают iPhone."
          )
        }
        Section {
          Picker("Язык приложения", selection: $appLanguage) {
            ForEach(Self.appLanguages, id: \.code) { lang in
              Text(lang.name).tag(lang.code)
            }
          }
          .accessibilityIdentifier("app-language-picker")
          .onChange(of: appLanguage) { _, code in
            if code.isEmpty {
              UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
              UserDefaults.standard.set([code], forKey: "AppleLanguages")
            }
          }
        } header: {
          Text("Язык приложения")
        } footer: {
          Text("Перезапустите приложение, чтобы сменить язык.")
        }
        Section("О приложении") {
          LabeledContent("Версия", value: Bundle.main.shortVersion)
        }
      }
      .onAppear { audioSource.refresh() }
      .task { await recognition.refreshCapableLocales() }
      .onChange(of: recognition.localeIdentifier) {
        Task { await recognition.refreshSelectedDownloadState() }
      }
      .onDisappear { audioSource.stopMetering() }
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
  @State private var storageIssues: [VoiceFilterStorageIssue]
  @State private var dictation = CallsignDictationService()
  @State private var downloadTask: Task<Void, Never>?
  @State private var recorder = VoiceEnrollmentRecorder()
  @State private var recordingSlot: PilotVoiceProfile.Slot?
  @State private var enrollMessage: String?
  private let installer = SpeakerModelPackInstaller()

  init(pipeline: VoiceFilterPipeline) {
    self.pipeline = pipeline
    _enabled = State(initialValue: pipeline.enabled)
    _callsignDraft = State(initialValue: pipeline.callSign?.raw ?? "")
    _modelPackState = State(initialValue: pipeline.modelPackState)
    _storageIssues = State(initialValue: pipeline.storageIssues)
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
          Text(
            enabled
              ? "Скрывать переговоры пилотов и нерелевантные обращения диспетчера."
              : "Все сегменты ATC отображаются."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }
      .accessibilityIdentifier("voicefilter-enabled-toggle")
      .onChange(of: enabled) { _, newValue in
        pipeline.setEnabled(newValue)
      }

      if !storageIssues.isEmpty {
        storageRecoveryContent
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Позывной воздушного судна")
          .font(.body.weight(.medium))
        HStack(spacing: 8) {
          TextField("N123AB / RA-89077 / SBI247", text: $callsignDraft)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled(true)
            .accessibilityIdentifier("voicefilter-callsign-field")
          dictationButton
        }
        Text(dictationHint)
          .font(.footnote)
          .foregroundStyle(dictation.unavailableReason == nil ? Color.secondary : Color.orange)
      }
      .onChange(of: callsignDraft) { _, newValue in
        pipeline.setCallSign(newValue.isEmpty ? nil : newValue)
      }
      .onChange(of: dictation.liveTranscript) { _, transcript in
        guard dictation.isListening else { return }
        let parsed = PhoneticCallsignParser.parse(transcript)
        if !parsed.isEmpty { callsignDraft = parsed }
      }

      modelPackContent
    } header: {
      Text("Голосовой фильтр ATC")
    } footer: {
      Text(
        "Распознавание выполняется только на устройстве. Аудио и образцы голоса не покидают iPhone. Подробности — ADR 0007 и ADR 0008."
      )
    }
  }

  private var dictationButton: some View {
    Button {
      Task { await dictation.toggle() }
    } label: {
      Image(systemName: dictation.isListening ? "stop.circle.fill" : "mic.circle.fill")
        .font(.system(size: 26))
        .foregroundStyle(dictation.isListening ? Color.red : Color.cyan)
        .symbolEffect(.pulse, isActive: dictation.isListening)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("voicefilter-callsign-dictate")
    .accessibilityLabel(
      dictation.isListening ? "Остановить голосовой ввод" : "Задать позывной голосом")
  }

  private var dictationHint: String {
    if let reason = dictation.unavailableReason {
      return reason
    }
    if dictation.isListening {
      return
        "Слушаю — продиктуйте позывной по буквам (например: «november one two three alpha bravo»)."
    }
    return callsignDraft.isEmpty
      ? "Без позывного фильтр пропускает все сегменты не-пилотов. Нажмите микрофон, чтобы задать голосом."
      : "Сегменты без совпадения по позывному будут скрываться, пока окно продолжения активно."
  }

  private var storageRecoveryContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Локальные настройки повреждены", systemImage: "exclamationmark.triangle.fill")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.orange)
      Text(VoiceFilterStorageIssue.userFacingSummary(storageIssues))
        .font(.footnote)
        .foregroundStyle(.secondary)
      Button("Сбросить повреждённые данные") {
        pipeline.clearStorageIssues()
        storageIssues = pipeline.storageIssues
        enabled = pipeline.enabled
        callsignDraft = pipeline.callSign?.raw ?? ""
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("voicefilter-storage-recovery")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("voicefilter-storage-corrupt")
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

  private func startDownload() {
    downloadTask?.cancel()
    transition(to: .acquiring(ModelPackAcquisition(phase: .downloading, fractionComplete: 0)))
    downloadTask = Task {
      do {
        let pack = try await installer.install { acquisition in
          Task { @MainActor in
            if case .acquiring = modelPackState {
              modelPackState = .acquiring(acquisition)
            }
          }
        }
        if Task.isCancelled { return }
        transition(to: .installed(pack))
      } catch is CancellationError {
        return
      } catch {
        if Task.isCancelled { return }
        transition(to: .failed(modelPackDownloadFailure(for: error)))
      }
      downloadTask = nil
    }
  }

  private func cancelDownload() {
    downloadTask?.cancel()
    downloadTask = nil
    transition(to: .absent)
  }

  private func deleteModelPack(_ pack: InstalledModelPack) async {
    do {
      let installer = installer
      try await Task.detached {
        try installer.uninstall(pack)
      }.value
      transition(to: .absent)
    } catch {
      transition(to: .failed(modelPackDeleteFailure(for: error)))
    }
  }

  private func enrollSubtitle(for slot: PilotVoiceProfile.Slot) -> String {
    if recordingSlot == slot {
      return "Идёт запись — говорите несколько секунд, затем «Остановить»."
    }
    if !identifierAvailable {
      return "Запись станет доступна, когда распознаватель будет подключён."
    }
    if pipeline.enrolledSlots.contains(slot) {
      return "Образец голоса записан. Запишите заново, чтобы обновить."
    }
    return "Запишите образец голоса для распознавания."
  }

  private func toggleEnrollment(slot: PilotVoiceProfile.Slot) async {
    if recordingSlot == slot {
      let result = await recorder.stop()
      recordingSlot = nil
      guard let result else {
        enrollMessage = "Запись не получилась — попробуйте снова."
        return
      }
      do {
        _ = try await pipeline.enrollPilot(
          slot: slot,
          label: slot == .primary ? "Pilot 1" : "Pilot 2",
          samples: result.samples,
          sampleRate: result.sampleRate
        )
        enrollMessage = "Голос сохранён для \(slot == .primary ? "Pilot 1" : "Pilot 2")."
      } catch LocalSpeakerIdentifierError.insufficientSpeech {
        enrollMessage = "Слишком тихо или коротко — запишите образец чётче."
      } catch {
        enrollMessage = "Не удалось сохранить образец голоса. Попробуйте снова."
      }
      return
    }

    enrollMessage = nil
    recordingSlot = slot
    await recorder.start()
    if !recorder.isRecording {
      recordingSlot = nil
      enrollMessage = recorder.unavailableReason ?? "Не удалось начать запись."
    }
  }

  private var absentContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Модель не установлена", systemImage: "arrow.down.circle")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(
        "Голосовой фильтр пилотов работает только после установки локального пакета модели. Загрузка — разовая, явная, по вашему запросу; аудио при этом не покидает устройство."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      Button("Скачать пакет голосового фильтра (≈ 15 МБ)") {
        startDownload()
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("voicefilter-modelpack-download-cta")
      Text(
        "Модель FluidAudio (\(SpeakerModelPackInstaller.source)) загружается один раз по этому запросу. С устройства уходит только запрос на скачивание модели — аудио, расшифровки и образцы голоса не передаются."
      )
      .font(.caption)
      .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("voicefilter-modelpack-absent")
  }

  private func acquiringContent(_ acquisition: ModelPackAcquisition) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(acquisitionTitle(acquisition.phase))
        .font(.subheadline.weight(.semibold))
      ProgressView(value: acquisition.fractionComplete)
        .accessibilityIdentifier("voicefilter-modelpack-progress")
      Text("\(acquisition.percentComplete)%")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("voicefilter-modelpack-percent")
      if let received = acquisition.bytesReceived, let total = acquisition.totalBytes {
        Text("\(byteString(received)) из \(byteString(total))")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Button("Отменить") {
        cancelDownload()
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("voicefilter-modelpack-cancel")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("voicefilter-modelpack-acquiring")
  }

  private func installedContent(_ pack: InstalledModelPack) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Модель установлена и проверена", systemImage: "checkmark.seal.fill")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.green)
      Text(
        "Пакет «\(pack.identifier)» · \(pack.embeddingDimension)-мерные эмбеддинги · \(byteString(pack.sizeBytes)). Распознавание выполняется офлайн."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)

      if !identifierAvailable {
        VStack(alignment: .leading, spacing: 6) {
          Label("Слот пилота недоступен", systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.orange)
          Text(
            "Пакет установлен, но локальный распознаватель не подключён в этой сборке, поэтому запись голоса отключена."
          )
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
            Text(enrollSubtitle(for: slot))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button(recordingSlot == slot ? "Остановить" : "Записать голос") {
            Task { await toggleEnrollment(slot: slot) }
          }
          .disabled(!identifierAvailable || (recordingSlot != nil && recordingSlot != slot))
          .buttonStyle(.bordered)
          .tint(recordingSlot == slot ? .red : nil)
          .accessibilityIdentifier(
            slot == .primary
              ? "voicefilter-enroll-pilot1"
              : "voicefilter-enroll-pilot2"
          )
        }
      }

      if let enrollMessage {
        Text(enrollMessage)
          .font(.footnote)
          .foregroundStyle(.cyan)
          .accessibilityIdentifier("voicefilter-enroll-message")
      }

      Button("Удалить пакет") {
        Task { await deleteModelPack(pack) }
      }
      .buttonStyle(.bordered)
      .tint(.red)
      .accessibilityIdentifier("voicefilter-modelpack-delete")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("voicefilter-modelpack-installed")
  }

  private func failedContent(_ failure: ModelPackFailure) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(modelPackFailureTitle(failure), systemImage: "xmark.octagon.fill")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.red)
      Text(failure.userSafeReason)
        .font(.footnote)
        .foregroundStyle(.secondary)
      if failure.isRetryable {
        Button("Повторить загрузку") {
          startDownload()
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("voicefilter-modelpack-retry")
      }
      Button("Продолжить без голосового фильтра") {
        transition(to: .absent)
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("voicefilter-modelpack-continue-without")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("voicefilter-modelpack-failed")
  }

  private func disabledContent(_ pack: InstalledModelPack) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Пакет установлен, фильтр выключен", systemImage: "pause.circle")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(
        "Модель «\(pack.identifier)» остаётся на устройстве. Включите фильтр выше или удалите пакет, чтобы освободить место."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      Button("Включить голосовой фильтр") {
        transition(to: .installed(pack))
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("voicefilter-modelpack-enable")
      Button("Удалить пакет (\(byteString(pack.sizeBytes)))") {
        Task { await deleteModelPack(pack) }
      }
      .buttonStyle(.bordered)
      .tint(.red)
      .accessibilityIdentifier("voicefilter-modelpack-delete")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("voicefilter-modelpack-disabled")
  }

  private func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  private func acquisitionTitle(_ phase: ModelPackAcquisition.Phase) -> String {
    switch phase {
    case .downloading:
      return "Загрузка модели…"
    case .importing:
      return "Установка модели…"
    }
  }

  private func modelPackFailureTitle(_ failure: ModelPackFailure) -> String {
    switch failure.kind {
    case .disk:
      return "Не удалось удалить модель"
    case .corruptState:
      return "Повреждено состояние модели"
    case .network, .checksum, .dimensionMismatch, .cancelled, .unknown:
      return "Не удалось установить модель"
    }
  }
}

func modelPackDownloadFailure(for error: Error) -> ModelPackFailure {
  if let installError = error as? ModelPackInstallError, installError.isIntegrityFailure {
    return ModelPackFailure(
      kind: .checksum,
      userSafeReason:
        "Пакет модели не прошёл проверку контрольной суммы или целостности. Повторите загрузку, чтобы скачать проверенную копию.",
      isRetryable: true
    )
  }

  return ModelPackFailure(
    kind: .network,
    userSafeReason:
      "Не удалось скачать пакет модели. Проверьте подключение к сети и попробуйте снова.",
    isRetryable: true
  )
}

func modelPackDeleteFailure(for error: Error) -> ModelPackFailure {
  ModelPackFailure(
    kind: .disk,
    userSafeReason:
      "Не удалось удалить пакет модели с устройства. Проверьте доступ к хранилищу и попробуйте позже.",
    isRetryable: false
  )
}

extension Bundle {
  fileprivate var shortVersion: String {
    (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
  }
}

private struct StartButton: View {
  let isStopVisible: Bool
  let disabled: Bool
  let action: () -> Void
  @State private var glowAngle = 0.0

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .fill(isStopVisible ? Color.red.opacity(0.85) : Color.gray.opacity(0.55))
        if !isStopVisible {
          // why: a glow that travels around the rim (rotating angular gradient) plus a
          // cyan dashed border, to pull attention to the idle Start control.
          Circle()
            .stroke(
              AngularGradient(
                gradient: Gradient(colors: [.cyan.opacity(0), .cyan, .cyan.opacity(0)]),
                center: .center),
              lineWidth: 4
            )
            .blur(radius: 5)
            .rotationEffect(.degrees(glowAngle))
          Circle()
            .strokeBorder(Color.cyan, style: StrokeStyle(lineWidth: 2.5, dash: [5, 4]))
        }
        Image(systemName: isStopVisible ? "stop.fill" : "mic.fill")
          .font(.system(size: 26, weight: .bold))
          .foregroundStyle(.white)
      }
      .frame(width: 64, height: 64)
      .opacity(disabled ? 0.45 : 1)
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .accessibilityIdentifier(isStopVisible ? "stop-button" : "start-button")
    .accessibilityLabel(isStopVisible ? "Стоп" : "Старт")
    .onAppear {
      withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
        glowAngle = 360
      }
    }
  }
}

private struct HintBubble: View {
  let text: LocalizedStringKey

  var body: some View {
    HStack(spacing: 5) {
      Text(text)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.black)
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      // why: a trail of shrinking circles pointing toward the button to its right.
      Circle().fill(.white).frame(width: 9, height: 9)
      Circle().fill(.white).frame(width: 6, height: 6)
      Circle().fill(.white).frame(width: 3.5, height: 3.5)
    }
    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    .transition(.opacity.combined(with: .scale(scale: 0.9)))
  }
}

private struct InputLevelBar: View {
  let level: Double

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.15))
        Capsule()
          .fill(.cyan)
          .frame(width: geo.size.width * CGFloat(max(0, min(1, level))))
      }
    }
  }
}

// why: the in-progress (partial) line must read as the SAME transcript, just live — not a
// visually foreign cyan italic block. It mirrors TranscriptSegmentCard's layout and
// typography (white card, same large monospaced text) with only a small "LIVE" badge +
// cyan border to signal it is still being recognized.
private struct PartialTranscriptCard: View {
  let text: String
  let isLandscape: Bool
  @ScaledMetric(relativeTo: .title) private var baseTranscriptSize: CGFloat = 30

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Label("LIVE", systemImage: "waveform")
          .font(.caption.monospaced().weight(.bold))
          .foregroundStyle(.cyan)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(.cyan.opacity(0.16), in: Capsule())
        Spacer()
      }
      Text(text)
        .font(
          .system(
            size: isLandscape ? baseTranscriptSize * (26.0 / 30.0) : baseTranscriptSize,
            weight: .semibold, design: .monospaced)
        )
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .minimumScaleFactor(0.6)
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
        .stroke(.cyan.opacity(0.35), lineWidth: 1)
    }
    .accessibilityIdentifier("partial-transcript")
  }
}

private struct TranscriptSegmentCard: View {
  let segment: TranscriptSegment
  let translatedText: String?
  let isLandscape: Bool
  // why: PRD F2 — the transcript honors Dynamic Type; @ScaledMetric scales the base
  // size with the user's accessibility text setting (minimumScaleFactor caps growth).
  @ScaledMetric(relativeTo: .title) private var baseTranscriptSize: CGFloat = 30
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      badgeRow
      transcriptText
      glossLine
      if expanded { detailRow }
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
    .contentShape(Rectangle())
    .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
    .accessibilityIdentifier("transcript-segment")
  }

  // why: PRD main view — tapping a segment expands its details (timestamp + confidence).
  private var detailRow: some View {
    HStack(spacing: 14) {
      Label(
        segment.startedAt.formatted(date: .omitted, time: .standard),
        systemImage: "clock")
      if segment.confidence > 0 {
        Text("conf \(segment.confidence.formatted(.percent.precision(.fractionLength(0))))")
      }
      Spacer(minLength: 0)
    }
    .font(.caption.monospacedDigit())
    .foregroundStyle(.white.opacity(0.6))
    .accessibilityIdentifier("transcript-segment-details")
  }

  private var badgeRow: some View {
    HStack(spacing: 8) {
      Text(segment.sourceLanguageCode.uppercased())
        .font(.caption.monospaced().weight(.bold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.white.opacity(0.12), in: Capsule())

      if segment.source == .demo {
        Text("DEMO")
          .font(.caption.monospaced().weight(.bold))
          .foregroundStyle(.cyan.opacity(0.9))
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(.cyan.opacity(0.14), in: Capsule())
      }

      if segment.requiresVerification {
        Text("VERIFY")
          .font(.caption.monospaced().weight(.bold))
          .foregroundStyle(.yellow)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(.yellow.opacity(0.16), in: Capsule())
      }

      Spacer()

      // why: confidence 0 = unverified (e.g. a Stop-committed partial) — hide the
      // meaningless "0%"; the VERIFY badge already carries the "unconfirmed" signal.
      if segment.confidence > 0 {
        Text(segment.confidence.formatted(.percent.precision(.fractionLength(0))))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.white.opacity(0.6))
      }
    }
  }

  @ViewBuilder
  private var transcriptText: some View {
    Text(segment.text)
      .font(
        .system(
          size: isLandscape ? baseTranscriptSize * (26.0 / 30.0) : baseTranscriptSize,
          weight: .semibold, design: .monospaced)
      )
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity, alignment: .leading)
      .minimumScaleFactor(0.6)
  }

  @ViewBuilder
  private var glossLine: some View {
    if let translatedText, !translatedText.isEmpty {
      Text(translatedText)
        .font(.system(size: isLandscape ? 18 : 20, weight: .regular, design: .rounded))
        .italic()
        .foregroundStyle(.cyan.opacity(0.85))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("transcript-translation")
    }
  }
}

#if DEBUG
  // why: the Canvas preview must not spin up the live AVAudioSession / mic — inject a
  // fake routing and an already-completed onboarding so the cockpit renders reliably
  // without device entitlements. DEBUG-only so none of this ships in release.
  private struct PreviewCompletedOnboardingStorage: OnboardingStateStorage {
    func loadHasCompletedOnboarding() -> Bool { true }
    func saveHasCompletedOnboarding(_ completed: Bool) {}
  }

  @MainActor private func previewCockpit() -> ContentView {
    let mic = PortSnapshot(portType: .builtInMic, portName: "iPhone", uid: "preview-mic")
    return ContentView(
      routing: FakeAudioSessionRouting(
        currentRoute: RouteSnapshot(inputs: [mic]), availableInputs: [mic]),
      onboarding: OnboardingState(storage: PreviewCompletedOnboardingStorage()))
  }

  #Preview("Portrait") { previewCockpit() }

  #Preview("Landscape", traits: .landscapeLeft) { previewCockpit() }
#endif
