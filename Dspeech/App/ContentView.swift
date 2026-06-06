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
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  init(
    engine: (any LiveTranscriptionEngine)? = nil,
    voiceFilter: VoiceFilterPipeline? = nil,
    routing: AudioSessionRouting = LiveAudioSessionRouting(),
    onboarding: OnboardingState? = nil,
    recognitionAvailability: (any OnDeviceLocaleAvailability)? = nil
  ) {
    let privacySettings = PrivacySettings()
    let recognitionSettings = RecognitionSettings(
      availability: recognitionAvailability ?? SystemOnDeviceLocaleAvailability())
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
        localeProvider: { recognitionSettings.activeLocaleIdentifier },
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
          "Tap Start and speak — the transcript will appear here.\nProcessed locally; audio never leaves your device."
      )
    case .requestingPermission:
      return String(localized: "Requesting microphone and speech recognition access…")
    case .ready, .listening:
      return String(localized: "Listening…")
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
    .task {
      await recognition.refreshCapableLocales()
      if translation.enabled { updateTranslationConfig() }
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
        sourceIdentifier = recognition.activeLocaleIdentifier,
        target = translation.targetLanguage,
        token = translationPreparationToken,
      ] session in
      guard let sourceIdentifier else { return }
      let source = Locale.Language(identifier: sourceIdentifier)
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
    guard let localeIdentifier = recognition.activeLocaleIdentifier else {
      translationConfig = nil
      coordinator.live.clearTranslations()
      return
    }
    let source = Locale.Language(identifier: localeIdentifier)
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
  // why: the coachmark hint bubbles are first-run nice-to-haves; at accessibility text sizes
  // they can't fit beside the floating controls without clipping, so suppress them there.
  private var showHints: Bool {
    liveViewModel.status == .idle && !dynamicTypeSize.isAccessibilitySize
  }

  private func startControls(isLandscape: Bool) -> some View {
    HStack(spacing: 12) {
      if showHints {
        HintBubble(text: "Tap to start recognition")
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
        Button(String(localized: "Clear")) {
          liveViewModel.reset()
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white.opacity(0.85))
        .accessibilityIdentifier("clear-button")
      }
      if let error = liveViewModel.lastErrorMessage {
        Text(RecognitionFailureText.userFacing(error))
          .font(.caption)
          .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.3))
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
          .accessibilityIdentifier("error-banner")
      }
      // why: reserve the bottom-trailing column so the error text never wraps under the
      // floating mic button (the obscured/unreadable banner the audit's elementDetection
      // catches); the banner stays left of the button and grows upward.
      Spacer(minLength: 84)
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
          .font(.system(isLandscape ? .title3 : .title2, design: .rounded).weight(.bold))
          .foregroundStyle(.white)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .layoutPriority(1)
          .accessibilityIdentifier("app-title")

        HStack(spacing: 8) {
          PrivacyBadge(mode: privacy.mode, isLandscape: isLandscape)
          RouteHealthChip(health: coordinator.routeMonitor.health, isLandscape: isLandscape)
        }
      }

      Spacer(minLength: 8)

      if showHints {
        HintBubble(text: "Settings are here")
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
    .accessibilityLabel(String(localized: "Settings"))
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
      .accessibilityLabel(String(localized: "On-device processing"))
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
    .accessibilityLabel(String(localized: "Capture source: \(health.displayLabel)"))
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
    ("", String(localized: "System")),
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
              Text(String(localized: "Active voice filter"))
                .font(.body.weight(.medium))
              Text(
                privacy.voiceFilterActive
                  ? String(
                    localized:
                      "The pre-ASR filter can only hide speech confidently recognized as the pilot's."
                  )
                  : String(
                    localized: "Pre-ASR filter is off; all audio buffers are passed to recognition."
                  )
              )
              .font(.footnote)
              .foregroundStyle(.secondary)
            }
          }
          .accessibilityIdentifier("voicefilter-active-toggle")
        } header: {
          Text(String(localized: "Privacy"))
        } footer: {
          Text(
            String(
              localized: "Dspeech processes audio locally only. Audio never leaves your device."))
        }

        if let voiceFilter {
          VoiceFilterSettingsSection(pipeline: voiceFilter)
        }

        Section {
          if let routeFailure = audioSource.routePreparationFailure {
            Text(routeFailure.userFacingMessage)
              .font(.footnote)
              .foregroundStyle(.red)
              .accessibilityIdentifier("audio-route-preparation-error")
          }
          if audioSource.hasSelectableInputs {
            Picker(String(localized: "Input"), selection: audioSourceBinding) {
              ForEach(audioSource.availableInputs, id: \.uid) { input in
                Text(input.portName).tag(input.uid)
              }
            }
            .accessibilityIdentifier("audio-source-picker")
          } else if audioSource.routePreparationFailure == nil {
            Text(
              String(
                localized:
                  "No input source detected. Connect a wired input (USB-C / TRRS) or use the built-in microphone."
              )
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
              audioSource.isMetering
                ? String(localized: "Stop test") : String(localized: "Test input level"),
              systemImage: audioSource.isMetering ? "stop.circle" : "waveform")
          }
          .disabled(captureActive)
          .accessibilityIdentifier("audio-meter-toggle")
          if audioSource.isMetering {
            HStack(spacing: 12) {
              Text(String(localized: "Level")).font(.footnote).foregroundStyle(.secondary)
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
          Text(String(localized: "Audio source"))
        } footer: {
          Text(
            String(
              localized:
                "Your choice is saved for this device. The built-in microphone is for testing; for the cockpit, connect a wired input."
            )
          )
          .fixedSize(horizontal: false, vertical: true)
        }
        Section(String(localized: "Recognition")) {
          switch recognition.localeAvailabilityState {
          case .loading:
            HStack {
              ProgressView()
              Text(String(localized: "Checking on-device recognition languages…"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("recognition-locale-loading")
          case .available:
            Picker(
              String(localized: "Recognition language"), selection: $recognition.localeIdentifier
            ) {
              ForEach(recognition.availableLocales) { locale in
                Text(locale.displayName).tag(Optional(locale.identifier))
              }
            }
            .accessibilityIdentifier("recognition-locale-picker")
          case .unavailable:
            VStack(alignment: .leading, spacing: 6) {
              Text(String(localized: "No on-device recognition languages available."))
                .font(.footnote)
                .foregroundStyle(.orange)
              Text(
                String(
                  localized:
                    "Check dictation languages in iPhone Settings. Dspeech won't fall back to cloud recognition in place of local mode."
                )
              )
              .font(.footnote)
              .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("recognition-locale-unavailable")
          }
          if recognition.selectedNeedsDownload {
            VStack(alignment: .leading, spacing: 6) {
              Text(
                String(
                  localized:
                    "The language “\(recognition.selectedDisplayName)” has not been downloaded yet for on-device recognition."
                )
              )
              .font(.footnote)
              .foregroundStyle(.orange)
              .accessibilityIdentifier("recognition-download-hint")
              Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                  UIApplication.shared.open(url)
                }
              } label: {
                Label(String(localized: "Open iPhone Settings"), systemImage: "gearshape")
              }
              .accessibilityIdentifier("recognition-download-language")
              Text(
                String(
                  localized:
                    "Then: General → Keyboard → Dictation Languages — turn on Dictation and add this language. The model downloads, and recognition works offline."
                )
              )
              .font(.footnote)
              .foregroundStyle(.secondary)
            }
          }
          LabeledContent(String(localized: "ASR model"), value: "Apple Speech")
          LabeledContent(String(localized: "Mode"), value: privacy.mode.displayName)
        }
        Section {
          Toggle(String(localized: "On-device translation"), isOn: $translation.enabled)
            .accessibilityIdentifier("translation-enabled-toggle")
          Picker(String(localized: "Target language"), selection: $translation.targetCode) {
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
          Text(String(localized: "Translation"))
        } footer: {
          Text(
            String(
              localized:
                "Translation runs on-device via Apple's system language packs. The first time you enable it, iOS offers to download a language pack. Audio and text never leave your iPhone."
            )
          )
          .fixedSize(horizontal: false, vertical: true)
        }
        Section {
          Picker(String(localized: "App language"), selection: $appLanguage) {
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
          Text(String(localized: "App language"))
        } footer: {
          Text(String(localized: "Restart the app to change the language."))
        }
        Section(String(localized: "About")) {
          LabeledContent(String(localized: "Version"), value: Bundle.main.shortVersion)
        }
      }
      .onAppear { audioSource.refresh() }
      .task { await recognition.refreshCapableLocales() }
      .onChange(of: recognition.localeIdentifier) {
        Task { await recognition.refreshSelectedDownloadState() }
      }
      .onDisappear { audioSource.stopMetering() }
      .navigationTitle(String(localized: "Settings"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(String(localized: "Done")) {
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
  @State private var modelPackAcquisition: ModelPackAcquisitionController
  @State private var storageIssues: [VoiceFilterStorageIssue]
  @State private var dictation = CallsignDictationService()
  @State private var recorder = VoiceEnrollmentRecorder()
  @State private var recordingSlot: PilotVoiceProfile.Slot?
  @State private var enrollMessage: String?
  private let installer: SpeakerModelPackInstaller

  init(pipeline: VoiceFilterPipeline) {
    self.pipeline = pipeline
    let installer = SpeakerModelPackInstaller()
    self.installer = installer
    _enabled = State(initialValue: pipeline.enabled)
    _callsignDraft = State(initialValue: pipeline.callSign?.raw ?? "")
    _modelPackAcquisition = State(
      initialValue: ModelPackAcquisitionController(
        initialState: pipeline.modelPackState,
        installer: installer
      ) { state in
        pipeline.setModelPackState(state)
      }
    )
    _storageIssues = State(initialValue: pipeline.storageIssues)
  }

  private var identifierAvailable: Bool {
    if case .ready = pipeline.capability { return true }
    return false
  }

  var body: some View {
    Section {
      // why: the description is its own row, not the Toggle's label — a Toggle reserves room
      // for the switch and clips a long localized subtitle (e.g. German) beside it.
      Toggle(isOn: $enabled) {
        Text(String(localized: "ATC/pilot filter"))
          .font(.body.weight(.medium))
      }
      .accessibilityIdentifier("voicefilter-enabled-toggle")
      .onChange(of: enabled) { _, newValue in
        pipeline.setEnabled(newValue)
      }
      Text(
        enabled
          ? String(localized: "Hide pilot transmissions and irrelevant ATC calls.")
          : String(localized: "All ATC segments are shown.")
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      if !storageIssues.isEmpty {
        storageRecoveryContent
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(String(localized: "Aircraft callsign"))
          .font(.body.weight(.medium))
        HStack(spacing: 8) {
          TextField("N123AB", text: $callsignDraft)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled(true)
            .accessibilityIdentifier("voicefilter-callsign-field")
          dictationButton
        }
        Text(dictationHint)
          .font(.footnote)
          .foregroundStyle(dictation.unavailableReason == nil ? Color.secondary : Color.orange)
          .fixedSize(horizontal: false, vertical: true)
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
      Text(String(localized: "ATC voice filter"))
    } footer: {
      Text(
        String(
          localized:
            "Recognition runs on-device only. Audio and voice samples never leave your iPhone. See ADR 0007 and ADR 0008 for details."
        )
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
      dictation.isListening
        ? String(localized: "Stop voice input") : String(localized: "Set callsign by voice"))
  }

  private var dictationHint: String {
    if let reason = dictation.unavailableReason {
      return reason
    }
    if dictation.isListening {
      return
        String(
          localized:
            "Listening — spell out the callsign (for example: \"november one two three alpha bravo\")."
        )
    }
    return callsignDraft.isEmpty
      ? String(
        localized:
          "Without a callsign, the filter passes all non-pilot segments. Tap the microphone to set it by voice."
      )
      : String(
        localized:
          "Segments with no callsign match will be hidden while the continuation window is active.")
  }

  private var storageRecoveryContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        String(localized: "Local settings are corrupted"),
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.orange)
      Text(VoiceFilterStorageIssue.userFacingSummary(storageIssues))
        .font(.footnote)
        .foregroundStyle(.secondary)
      Button(String(localized: "Reset corrupted data")) {
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
    switch modelPackAcquisition.state {
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
    modelPackAcquisition.setState(state)
  }

  private func startDownload() {
    modelPackAcquisition.startDownload()
  }

  private func cancelDownload() {
    modelPackAcquisition.cancelDownload()
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
      return String(localized: "Recording — speak for a few seconds, then tap Stop.")
    }
    if !identifierAvailable {
      return String(localized: "Recording becomes available once the recognizer is connected.")
    }
    if pipeline.enrolledSlots.contains(slot) {
      return String(localized: "Voice sample recorded. Record again to update it.")
    }
    return String(localized: "Record a voice sample for recognition.")
  }

  private func toggleEnrollment(slot: PilotVoiceProfile.Slot) async {
    if recordingSlot == slot {
      let result = await recorder.stop()
      recordingSlot = nil
      guard let result else {
        enrollMessage = String(localized: "Recording failed — try again.")
        return
      }
      do {
        _ = try await pipeline.enrollPilot(
          slot: slot,
          label: slot == .primary ? "Pilot 1" : "Pilot 2",
          samples: result.samples,
          sampleRate: result.sampleRate
        )
        enrollMessage = String(
          localized: "Voice saved for \(slot == .primary ? "Pilot 1" : "Pilot 2").")
      } catch LocalSpeakerIdentifierError.insufficientSpeech {
        enrollMessage = String(localized: "Too quiet or too short — record a clearer sample.")
      } catch {
        enrollMessage = String(localized: "Couldn't save the voice sample. Try again.")
      }
      return
    }

    enrollMessage = nil
    recordingSlot = slot
    await recorder.start()
    if !recorder.isRecording {
      recordingSlot = nil
      enrollMessage = recorder.unavailableReason ?? String(localized: "Couldn't start recording.")
    }
  }

  private var absentContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "arrow.down.circle")
        Text(String(localized: "Model not installed"))
          .fixedSize(horizontal: false, vertical: true)
      }
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.secondary)
      Text(
        String(
          localized:
            "The pilot voice filter works only after the local model pack is installed. The download is one-time, explicit, and on your request; audio never leaves your device."
        )
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Button {
        startDownload()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "arrow.down.circle.fill")
          Text(String(localized: "Download voice filter pack (≈ 15 MB)"))
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.vertical, 3)
      }
      .buttonStyle(.borderedProminent)
      .tint(.cyan)
      .foregroundStyle(.black)
      .controlSize(.large)
      .padding(.top, 2)
      .accessibilityIdentifier("voicefilter-modelpack-download-cta")
      Text(
        String(
          localized:
            "The FluidAudio model (\(SpeakerModelPackInstaller.source)) is downloaded once at this request. Only the model download request leaves the device — audio, transcripts and voice samples are not transmitted."
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
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
        Text(String(localized: "\(byteString(received)) of \(byteString(total))"))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Button(String(localized: "Cancel")) {
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
      Label(String(localized: "Model installed and verified"), systemImage: "checkmark.seal.fill")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.green)
      Text(
        String(
          localized:
            "Pack “\(pack.identifier)” · \(pack.embeddingDimension)-dimensional embeddings · \(byteString(pack.sizeBytes)). Recognition runs offline."
        )
      )
      .font(.footnote)
      .foregroundStyle(.secondary)

      if !identifierAvailable {
        VStack(alignment: .leading, spacing: 6) {
          Label(
            String(localized: "Pilot slot unavailable"),
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.orange)
          Text(
            String(
              localized:
                "The pack is installed, but the local recognizer isn't connected in this build, so voice recording is disabled."
            )
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
          Button(
            recordingSlot == slot ? String(localized: "Stop") : String(localized: "Record voice")
          ) {
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

      Button(String(localized: "Delete pack")) {
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
        Button(String(localized: "Retry download")) {
          startDownload()
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("voicefilter-modelpack-retry")
      }
      Button(String(localized: "Continue without voice filter")) {
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
      Label(String(localized: "Pack installed, filter off"), systemImage: "pause.circle")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(
        String(
          localized:
            "The model “\(pack.identifier)” stays on the device. Enable the filter above or delete the pack to free up space."
        )
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      Button(String(localized: "Enable voice filter")) {
        transition(to: .installed(pack))
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("voicefilter-modelpack-enable")
      Button(String(localized: "Delete pack (\(byteString(pack.sizeBytes)))")) {
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
      return String(localized: "Downloading model…")
    case .importing:
      return String(localized: "Installing model…")
    }
  }

  private func modelPackFailureTitle(_ failure: ModelPackFailure) -> String {
    switch failure.kind {
    case .disk:
      return String(localized: "Couldn't delete the model")
    case .corruptState:
      return String(localized: "Model state corrupted")
    case .network, .checksum, .dimensionMismatch, .cancelled, .unknown:
      return String(localized: "Couldn't install the model")
    }
  }
}

extension Bundle {
  fileprivate var shortVersion: String {
    (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
  }
}

// why: XCUITest's `performAccessibilityAudit` and element queries require the app to reach an
// idle state; an infinite `repeatForever` decorative animation keeps the run loop perpetually
// "busy" and intermittently destabilizes audits and hit-testing on the hosted CI simulator.
// Honoring reduce-motion is also a genuine accessibility win (continuous motion is exactly what
// that setting asks us to suppress); the launch flag lets UI/audit tests force the same stable
// state without depending on a device-level setting XCUITest cannot toggle.
enum DecorativeMotion {
  static let isDisabledForUITests: Bool =
    CommandLine.arguments.contains("-dspeech.uitest.reduce-animations")
}

private struct StartButton: View {
  let isStopVisible: Bool
  let disabled: Bool
  let action: () -> Void
  @State private var glowAngle = 0.0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var animatesGlow: Bool {
    !reduceMotion && !DecorativeMotion.isDisabledForUITests
  }

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
    .accessibilityLabel(isStopVisible ? String(localized: "Stop") : String(localized: "Start"))
    .onAppear {
      guard animatesGlow else { return }
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
        .frame(maxWidth: 230, alignment: .trailing)
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
        .font(.system(isLandscape ? .title2 : .title, design: .monospaced).weight(.semibold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(red: 0.07, green: 0.08, blue: 0.10),
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
  // why: PRD F2 — the transcript honors Dynamic Type via a semantic monospaced text style
  // (.title / .title2) so the audit credits full Dynamic-Type support.
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
      Color(red: 0.07, green: 0.08, blue: 0.10),
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
    .foregroundStyle(.white.opacity(0.85))
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
          .foregroundStyle(.white.opacity(0.85))
      }
    }
  }

  @ViewBuilder
  private var transcriptText: some View {
    Text(segment.text)
      .font(.system(isLandscape ? .title2 : .title, design: .monospaced).weight(.semibold))
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var glossLine: some View {
    if let translatedText, !translatedText.isEmpty {
      Text(translatedText)
        .font(.system(isLandscape ? .body : .title3, design: .rounded))
        .italic()
        .foregroundStyle(.cyan)
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
