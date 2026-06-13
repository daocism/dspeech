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
  @State private var transcriptStore: (any TranscriptStoring)?
  @State private var showSettings: Bool = false
  @State private var showHistory: Bool = false
  @State private var showClearConfirmation: Bool = false
  @State private var showSuppressedReview: Bool = false
  @State private var followsLiveTranscript: Bool = true
  @State private var transcriptViewportHeight: CGFloat = 0
  @State private var onboarding: OnboardingState
  @State private var translationConfig: TranslationSession.Configuration?
  @State private var translationPreparationToken = UUID()
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  init(
    engine: (any LiveTranscriptionEngine)? = nil,
    voiceFilter: VoiceFilterPipeline? = nil,
    routing: AudioSessionRouting = LiveAudioSessionRouting(),
    onboarding: OnboardingState? = nil,
    recognitionAvailability: (any OnDeviceLocaleAvailability)? = nil,
    transcriptStore: (any TranscriptStoring)? = nil
  ) {
    let privacySettings = PrivacySettings()
    let recognitionSettings = RecognitionSettings(
      availability: recognitionAvailability ?? SystemOnDeviceLocaleAvailability())
    let persistentTranscriptStore: (any TranscriptStoring)?
    var transcriptStoreUnavailable = false
    if let transcriptStore {
      persistentTranscriptStore = transcriptStore
    } else {
      do {
        persistentTranscriptStore = try FileTranscriptStore()
      } catch {
        persistentTranscriptStore = nil
        transcriptStoreUnavailable = true
      }
    }
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
    #if DEBUG
      let debugScriptedEngine: (any LiveTranscriptionEngine)? =
        RenderStableScriptedLiveTranscriptionEngine.makeFromLaunchArguments()
    #else
      let debugScriptedEngine: (any LiveTranscriptionEngine)? = nil
    #endif
    let whisperKitInstaller = WhisperKitModelInstaller()
    let resolvedEngine =
      engine
      ?? debugScriptedEngine
      ?? Self.makeLiveTranscriptionEngine(
        recognition: recognitionSettings,
        voiceFilter: filter,
        whisperKitInstaller: whisperKitInstaller
      )
    let translationSettings = TranslationSettings()
    let live = LiveTranscriptionViewModel(
      engine: resolvedEngine,
      transcriptStore: persistentTranscriptStore,
      recognitionLocaleIdentifier: { recognitionSettings.activeLocaleIdentifier },
      recognitionTransmissionGapSeconds: { recognitionSettings.transmissionGapSeconds },
      voiceFilter: filter,
      translator: LocalTranslationService(backend: AppleTranslationService()),
      translationTarget: { translationSettings.enabled ? translationSettings.targetLanguage : nil }
    )
    #if DEBUG
      if CommandLine.arguments.contains("-dspeech.uitest.seed-suppressed") {
        live.seedSuppressedDemoSegmentForUITests()
      }
    #endif
    if transcriptStoreUnavailable {
      live.recordPersistenceUnavailable()
    }
    let monitor = RouteHealthMonitor(routing: routing)
    _privacy = State(initialValue: privacySettings)
    _recognition = State(initialValue: recognitionSettings)
    _voiceFilter = State(initialValue: filter)
    _translation = State(initialValue: translationSettings)
    _audioSource = State(initialValue: AudioSourceController(routing: routing))
    _transcriptStore = State(initialValue: persistentTranscriptStore)
    _onboarding = State(initialValue: onboarding ?? OnboardingState())
    _coordinator = State(
      initialValue: CaptureCoordinator(
        live: live,
        routeMonitor: monitor
      ))
  }

  private var liveViewModel: LiveTranscriptionViewModel { coordinator.live }

  private static func makeLiveTranscriptionEngine(
    recognition: RecognitionSettings,
    voiceFilter: VoiceFilterPipeline,
    whisperKitInstaller: WhisperKitModelInstaller
  ) -> any LiveTranscriptionEngine {
    switch recognition.engineChoice {
    case .apple:
      return makeAppleSpeechLiveTranscriptionEngine(
        recognition: recognition,
        voiceFilter: voiceFilter
      )
    case .whisperKit:
      guard whisperKitInstaller.state.isInstalled,
        whisperKitInstaller.installedModelFolderURL != nil
      else {
        DspeechLog.engine.error(
          "whisperkit engine selected but local model is not installed; falling back to apple speech"
        )
        return makeAppleSpeechLiveTranscriptionEngine(
          recognition: recognition,
          voiceFilter: voiceFilter
        )
      }
      DspeechLog.engine.info("whisperkit engine selected with installed local model")
      return WhisperKitLiveTranscriptionEngine(
        transcriber: WhisperKitTranscriberAdapter(),
        installedModelFolderURL: { whisperKitInstaller.installedModelFolderURL },
        localeProvider: { recognition.localeIdentifier ?? recognition.activeLocaleIdentifier },
        bufferGate: VoiceFilterSpeechAudioBufferGate(pipeline: voiceFilter)
      )
    }
  }

  private static func makeAppleSpeechLiveTranscriptionEngine(
    recognition: RecognitionSettings,
    voiceFilter: VoiceFilterPipeline
  ) -> AppleSpeechLiveTranscriptionEngine {
    AppleSpeechLiveTranscriptionEngine(
      localeProvider: { recognition.activeLocaleIdentifier },
      bufferGate: VoiceFilterSpeechAudioBufferGate(pipeline: voiceFilter),
      contextualCallSignProvider: { voiceFilter.callSign?.raw }
    )
  }

  private var filteredTransmissionsForReview: [Transmission] {
    liveViewModel.filteredTransmissions
  }

  private var canClearTranscriptView: Bool {
    !liveViewModel.segments.isEmpty || !liveViewModel.displayedTransmissions.isEmpty
      || !liveViewModel.filteredTransmissions.isEmpty || !liveViewModel.partialText.isEmpty
  }

  private var readableContentMaxWidth: CGFloat {
    horizontalSizeClass == .regular ? 720 : .infinity
  }

  private var demoTranscriptSegmentsForDisplay: [TranscriptSegment] {
    // why: the demo transcript is a first-run illustration ONLY — show it solely before the
    // first Start, never over real content and never again after a real session (the
    // "press Stop and my transcript turns back into demo" bug).
    guard liveViewModel.visibleSegments.isEmpty,
      liveViewModel.partialText.isEmpty,
      !liveViewModel.hasEverStarted
    else {
      return []
    }
    return TranscriptDemoViewModel.demo.segments
  }

  private func updateIdleTimerDisabled() {
    UIApplication.shared.isIdleTimerDisabled =
      scenePhase == .active && liveViewModel.canStopCurrentSession
  }

  // why: the localized first-run invitation, reused for the idle state and the failure state so
  // the specific failure message is shown ONCE (in the bottom error banner) instead of twice.
  private var idleInviteText: String {
    String(
      localized:
        "Tap Start and speak — the transcript will appear here.\nProcessed locally; audio never leaves your device."
    )
  }

  private var emptyStateText: String {
    switch liveViewModel.status {
    case .idle, .stopped, .failed:
      // why: the on-device-locale readiness check is Apple-Speech-specific. WhisperKit
      // is multilingual and has no Apple per-language asset, so its idle screen must NOT
      // claim "no recognition languages" — that gate only applies to the Apple engine.
      if recognition.engineChoice == .whisperKit {
        return idleInviteText
      }
      // why: before the first Start, reflect whether on-device recognition is actually ready —
      // tapping Start while locales are still loading otherwise fails with a misleading
      // "no language" error. The specific failure detail renders in the bottom error banner.
      switch recognition.localeAvailabilityState {
      case .loading:
        return String(localized: "Checking on-device recognition languages…")
      case .unavailable:
        return String(localized: "No on-device recognition languages available.")
      case .available:
        return idleInviteText
      }
    case .requestingPermission:
      return String(localized: "Requesting microphone and speech recognition access…")
    case .ready, .listening:
      return String(localized: "Listening…")
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
          MainControlBar(
            isLandscape: isLandscape,
            privacyMode: privacy.mode,
            routeHealth: coordinator.routeMonitor.health,
            isSessionActive: liveViewModel.canStopCurrentSession,
            openHistory: { showHistory = true },
            openSettings: { showSettings = true }
          )
          bannerStack()
          filteredCountPill()
          // why: reserve real layout space (outside the auto-scrolling transcript) for the
          // first-run "Settings are here" coachmark that floats under the gear, so the first
          // transcript card renders BELOW it. A scroll content inset did not work — the
          // transcript auto-scrolls to the latest card, carrying any top inset off-screen,
          // so the bubble kept obscuring the first card's text + ⋮ button (2026-06-13 review).
          if showHints {
            Color.clear.frame(height: isLandscape ? 40 : 56)
          }
          transcriptArea(isLandscape: isLandscape)
        }
        .frame(maxWidth: readableContentMaxWidth, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, isLandscape ? 16 : 18)
        .padding(.top, isLandscape ? 6 : 10)
        .padding(.bottom, isLandscape ? 8 : 14)
        // why: the first-run settings hint is a free-floating callout UNDER the gear —
        // inline in the bar it fought title/chips/buttons for width on long locales and
        // degraded into truncation (2026-06-11 visual review).
        .overlay(alignment: .topTrailing) {
          if showHints {
            HintBubble(text: String(localized: "Settings are here"), pointer: .up)
              .padding(.top, isLandscape ? 62 : 84)
              .padding(.trailing, isLandscape ? 16 : 18)
          }
        }
        // why: bottom-anchored above the floating controls — the hint appears with the
        // FIRST transmission card, which renders at the top; a top overlay sat on that
        // card and obscured it (2026-06-12 visual review). Bottom space is empty at
        // appearance time and sits next to the microphone the hint talks about.
        .overlay(alignment: .bottom) {
          if liveViewModel.oneTimeNoAnchorHintVisible {
            NoAnchorTransmissionHint(
              text: String(
                localized:
                  "Without a callsign, the filter passes all non-pilot transmissions. Tap the microphone to set it by voice."
              ),
              dismiss: { liveViewModel.dismissNoAnchorHint() }
            )
            .padding(.bottom, isLandscape ? 84 : 112)
            .padding(.horizontal, 18)
          }
        }

        // why: Start + Clear/error float over the transcript (no opaque footer strip);
        // the transcript fills the full height and scrolls its content clear of them.
        BottomLeftControls(
          isLandscape: isLandscape,
          maxWidth: readableContentMaxWidth,
          canClearTranscriptView: canClearTranscriptView,
          error: liveViewModel.lastErrorMessage,
          clearTranscript: { showClearConfirmation = true }
        )
        FloatingStartControls(
          isLandscape: isLandscape,
          maxWidth: readableContentMaxWidth,
          showHints: showHints,
          isStopVisible: liveViewModel.canStopCurrentSession,
          disabled: liveViewModel.status == .requestingPermission
        ) {
          Task { await toggleListening() }
        }
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
        voiceFilter: voiceFilter,
        onVoiceFilterDisabled: { liveViewModel.unhideAllSuppressedSegments() }
      )
      .presentationSizing(.form)
    }
    .sheet(isPresented: $showHistory) {
      if let transcriptStore {
        SessionHistoryView(store: transcriptStore)
      } else {
        ContentUnavailableView(
          String(localized: "Session history unavailable"),
          systemImage: "clock.badge.questionmark",
          description: Text(String(localized: "Transcript storage is not available."))
        )
        .preferredColorScheme(.dark)
      }
    }
    .sheet(isPresented: $showSuppressedReview) {
      FilteredTransmissionsReviewSheet(
        transmissions: filteredTransmissionsForReview,
        showTransmission: { liveViewModel.showFilteredTransmission(id: $0.id) }
      )
    }
    .confirmationDialog(
      String(localized: "Clear current transcript?"),
      isPresented: $showClearConfirmation,
      titleVisibility: .visible
    ) {
      Button(String(localized: "Clear view"), role: .destructive) {
        liveViewModel.reset()
      }
      Button(String(localized: "Cancel"), role: .cancel) {}
    } message: {
      Text(
        String(
          localized:
            "This clears the cockpit view only. Saved session history stays on this device."))
    }
    .onAppear {
      coordinator.beginObservingRouteChanges()
      audioSource.applyPersistedPreference()
      // why: .onChange(of:) does not fire for state restored from UserDefaults, so
      // a returning user who left translation ON needs the config armed here — it
      // drives .translationTask -> prepareTranslation (the only pack-download path).
      updateTranslationConfig()
      updateIdleTimerDisabled()
    }
    .task {
      await recognition.refreshCapableLocales()
      if translation.enabled { updateTranslationConfig() }
      #if DEBUG
        // why: headless E2E seam — lets an automated real-audio run (fixture piped
        // into the simulator mic) start the live engine without a GUI tap. DEBUG-only;
        // a release build can never auto-arm the microphone.
        if CommandLine.arguments.contains("-dspeech.e2e.autostart-listening") {
          await liveViewModel.start()
        }
      #endif
    }
    .onDisappear {
      coordinator.endObservingRouteChanges()
      UIApplication.shared.isIdleTimerDisabled = false
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
        coordinator.refreshOnForeground()
        Task { await recognition.refreshCapableLocales() }
      } else if newPhase == .background {
        coordinator.stopForBackground()
      }
      updateIdleTimerDisabled()
    }
    .onChange(of: liveViewModel.canStopCurrentSession) { _, _ in
      updateIdleTimerDisabled()
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
    if let failure = Self.sameLanguageTranslationFailure(
      sourceIdentifier: localeIdentifier,
      targetCode: translation.targetCode
    ) {
      translationConfig = nil
      coordinator.live.clearTranslations()
      let token = coordinator.live.beginTranslationPreparation()
      translationPreparationToken = token
      coordinator.live.recordTranslationPreparationFailure(failure, token: token)
      return
    }
    translationPreparationToken = coordinator.live.beginTranslationPreparation()
    translationConfig = TranslationSession.Configuration(
      source: source, target: translation.targetLanguage)
  }

  static func sameLanguageTranslationFailure(
    sourceIdentifier: String,
    targetCode: String
  ) -> TranslationFailure? {
    let source = Locale.Language(identifier: sourceIdentifier)
    let target = Locale.Language(identifier: targetCode)
    guard let sourceCode = source.languageCode?.identifier.lowercased(),
      let targetCode = target.languageCode?.identifier.lowercased(),
      sourceCode == targetCode
    else { return nil }
    return .languagePairingUnsupported(source: source, target: target)
  }

  private func glossText(for segment: TranscriptSegment) -> String? {
    // why: only ever surface a real engine-produced translation — never the demo
    // fixture's canned translatedText, which would be a fake-AI gloss (CLAUDE.md #2)
    // and would render instantly offline with no language-pack download.
    guard translation.enabled, segment.source != .demo else { return nil }
    return liveViewModel.translations[segment.id]
  }

  @ViewBuilder
  private func bannerStack() -> some View {
    VStack(spacing: 6) {
      routeBanner()
      backgroundStopNoticeBanner()
      persistenceFailureBanner()
      translationFailureBanner()
    }
  }

  @ViewBuilder
  private func filteredCountPill() -> some View {
    let count = liveViewModel.filteredTransmissions.count
    if count > 0 {
      HStack {
        Button {
          showSuppressedReview = true
        } label: {
          Label(
            String(localized: "\(count) filtered"),
            systemImage: "line.3.horizontal.decrease.circle.fill"
          )
          .font(.caption.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .fixedSize()
          .foregroundStyle(.yellow)
          .padding(.horizontal, 12)
          .frame(minHeight: 44)
          .background(.yellow.opacity(0.14), in: Capsule())
          .overlay {
            Capsule().stroke(.yellow.opacity(0.42), lineWidth: 1)
          }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("filtered-transmissions-pill")
        .accessibilityLabel(String(localized: "\(count) filtered transmissions"))
        Spacer(minLength: 0)
      }
    }
  }

  @ViewBuilder
  private func routeBanner() -> some View {
    if let message = coordinator.routeBanner ?? coordinator.startBlockedMessage {
      HStack(spacing: 8) {
        Image(systemName: coordinator.canStart ? "exclamationmark.triangle.fill" : "mic.slash.fill")
          .font(.footnote.weight(.semibold))
        Text(message)
          .font(.footnote.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
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
  private func backgroundStopNoticeBanner() -> some View {
    if coordinator.stoppedForBackgroundNotice {
      HStack(spacing: 8) {
        Image(systemName: "info.circle.fill")
          .font(.footnote.weight(.semibold))
        Text(String(localized: "Listening stopped while the app was in the background."))
          .font(.footnote.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Button {
          coordinator.dismissStoppedForBackgroundNotice()
        } label: {
          Image(systemName: "xmark")
            .font(.caption.weight(.bold))
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("background-stop-dismiss")
        .accessibilityLabel(String(localized: "Dismiss background stop notice"))
      }
      .foregroundStyle(Color.white.opacity(0.86))
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color.white.opacity(0.26), lineWidth: 1)
      }
      .accessibilityIdentifier("background-stop-banner")
    }
  }

  @ViewBuilder
  private func persistenceFailureBanner() -> some View {
    if let persistenceFailure = liveViewModel.persistenceFailure {
      HStack(spacing: 8) {
        Image(systemName: "externaldrive.badge.exclamationmark")
          .font(.footnote.weight(.semibold))
        Text(persistenceFailure)
          .font(.footnote.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Button {
          liveViewModel.dismissPersistenceFailure()
        } label: {
          Image(systemName: "xmark")
            .font(.caption.weight(.bold))
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("persistence-failure-dismiss")
        .accessibilityLabel(String(localized: "Dismiss transcript storage warning"))
      }
      .foregroundStyle(Color.orange)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color.orange.opacity(0.4), lineWidth: 1)
      }
      .accessibilityIdentifier("persistence-failure-banner")
    }
  }

  @ViewBuilder
  private func translationFailureBanner() -> some View {
    if translation.enabled, let translationFailure = liveViewModel.translationFailure {
      HStack(spacing: 8) {
        Image(
          systemName: liveViewModel.translationUnavailable
            ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.footnote.weight(.semibold))
        Text(TranslationFailureText.userFacing(translationFailure))
          .font(.footnote.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Button {
          showSettings = true
        } label: {
          Text(String(localized: "Translation settings"))
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(.black.opacity(0.32), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("translation-settings-action")
      }
      .foregroundStyle(Color.cyan)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color.cyan.opacity(0.38), lineWidth: 1)
      }
      .accessibilityIdentifier("translation-failure-banner")
    }
  }

  @ViewBuilder
  private func transcriptArea(isLandscape: Bool) -> some View {
    let demoSegments = demoTranscriptSegmentsForDisplay
    let displayedTransmissions = liveViewModel.displayedTransmissions
    if demoSegments.isEmpty && displayedTransmissions.isEmpty && liveViewModel.partialText.isEmpty {
      VStack {
        Spacer()
        Text(emptyStateText)
          // why: PRD F2 — primary guidance text honors Dynamic Type via a semantic style
          // (scales with the user's accessibility text size) instead of a fixed point size.
          .font(.system(isLandscape ? .body : .title3, design: .rounded).weight(.medium))
          .foregroundStyle(.white.opacity(0.7))
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
          .accessibilityIdentifier("transcript-empty-state")
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollViewReader { proxy in
        ZStack(alignment: .bottom) {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: isLandscape ? 10 : 12) {
              ForEach(demoSegments) { segment in
                TranscriptSegmentCard(
                  segment: segment,
                  translatedText: glossText(for: segment),
                  isLandscape: isLandscape
                )
              }
              ForEach(displayedTransmissions) { transmission in
                TransmissionTranscriptCard(
                  transmission: transmission,
                  isLandscape: isLandscape
                )
              }
              if !liveViewModel.partialText.isEmpty {
                PartialTranscriptCard(text: liveViewModel.partialText, isLandscape: isLandscape)
              }
              Color.clear
                .frame(height: 1)
                .id(TranscriptScrollAnchor.bottom)
                .background {
                  GeometryReader { geometry in
                    Color.clear.preference(
                      key: TranscriptBottomOffsetPreferenceKey.self,
                      value: geometry.frame(in: .named("transcript-scroll")).maxY)
                  }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          // why: floating controls (Start/mic, jump-to-live) overlay the scroll area;
          // a bottom content margin keeps transcript text from ever sliding UNDER them —
          // the audit's "potentially inaccessible text" class — at every scroll offset,
          // not just after the last card. In the first-run hint state the cluster is taller
          // (the "Tap to start" coachmark sits beside/above the mic), so reserve extra room
          // or the last demo card renders under the bubble (2026-06-13 visual review).
          .contentMargins(.bottom, showHints ? 168 : 104, for: .scrollContent)
          .scrollIndicators(.hidden)
          .coordinateSpace(name: "transcript-scroll")
          .background {
            GeometryReader { geometry in
              Color.clear.preference(
                key: TranscriptViewportHeightPreferenceKey.self,
                value: geometry.size.height)
            }
          }
          .simultaneousGesture(
            DragGesture(minimumDistance: 6).onChanged { _ in
              followsLiveTranscript = false
            }
          )
          .onPreferenceChange(TranscriptViewportHeightPreferenceKey.self) { height in
            transcriptViewportHeight = height
          }
          .onPreferenceChange(TranscriptBottomOffsetPreferenceKey.self) { bottomY in
            guard transcriptViewportHeight > 0, bottomY > 0 else { return }
            if bottomY <= transcriptViewportHeight + 24 {
              followsLiveTranscript = true
            }
          }
          .onAppear {
            scrollTranscriptToLive(proxy, animated: false)
          }
          .onChange(of: demoSegments.map(\.id)) { _, _ in
            scrollTranscriptToLive(proxy)
          }
          .onChange(of: displayedTransmissions.map(\.id)) { _, _ in
            scrollTranscriptToLive(proxy)
          }
          .onChange(of: liveViewModel.partialText) { _, _ in
            scrollTranscriptToLive(proxy)
          }

          if !followsLiveTranscript {
            Button {
              followsLiveTranscript = true
              scrollTranscriptToLive(proxy)
            } label: {
              Label(String(localized: "Jump to live"), systemImage: "arrow.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(.cyan, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 90)
            .accessibilityIdentifier("jump-to-live")
          }
        }
      }
    }
  }

  private func scrollTranscriptToLive(_ proxy: ScrollViewProxy, animated: Bool = true) {
    guard followsLiveTranscript else { return }
    if animated {
      withAnimation(.easeOut(duration: 0.18)) {
        proxy.scrollTo(TranscriptScrollAnchor.bottom, anchor: .bottom)
      }
    } else {
      proxy.scrollTo(TranscriptScrollAnchor.bottom, anchor: .bottom)
    }
  }

  // why: launch-time hints show only in the pristine idle state (before the first
  // Start), so they grab attention once and never nag after the user has used the app.
  // why: the coachmark hint bubbles are first-run nice-to-haves; at accessibility text sizes
  // they can't fit beside the floating controls without clipping, so suppress them there.
  // why: the hint bubbles are FIRST-RUN nudges for an empty cockpit. Shown over content
  // they cover real controls (the "Tap to start" bubble sits exactly on the Clear button —
  // an obscured-hit-region defect), so any prior session or any on-screen segments retire
  // them.
  private var showHints: Bool {
    liveViewModel.status == .idle && !dynamicTypeSize.isAccessibilitySize
      && !liveViewModel.hasEverStarted && liveViewModel.segments.isEmpty
      && liveViewModel.displayedTransmissions.isEmpty && liveViewModel.filteredTransmissions.isEmpty
  }

  private func toggleListening() async {
    // why: if the on-device locale check is still in flight, let it settle before starting so the
    // first cold-launch tap uses a resolved locale instead of racing into a misleading
    // "recognition-locale-unavailable" failure. No-op when stopping or already settled, and a tap
    // is never silently dropped (the control stays enabled).
    if !liveViewModel.canStopCurrentSession,
      recognition.localeAvailabilityState == .loading
    {
      await recognition.refreshCapableLocales()
    }
    await coordinator.toggle()
  }

}

private enum TranscriptScrollAnchor {
  static let bottom = "transcript-live-bottom"
}

private struct TranscriptViewportHeightPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}

#if DEBUG
  @MainActor
  private final class RenderStableScriptedLiveTranscriptionEngine: LiveTranscriptionEngine {
    private var continuation: AsyncStream<LiveTranscriptionEvent>.Continuation?
    private var finalTask: Task<Void, Never>?
    private(set) var status: LiveTranscriptionStatus = .idle

    static func makeFromLaunchArguments(
      _ arguments: [String] = CommandLine.arguments
    ) -> RenderStableScriptedLiveTranscriptionEngine? {
      guard ScriptedLiveTranscriptionEngine.makeFromLaunchArguments(arguments) != nil else {
        return nil
      }
      return RenderStableScriptedLiveTranscriptionEngine()
    }

    func events() -> AsyncStream<LiveTranscriptionEvent> {
      AsyncStream<LiveTranscriptionEvent> { continuation in
        self.continuation = continuation
        continuation.yield(.status(self.status))
      }
    }

    func start() async {
      transition(to: .requestingPermission)
      transition(to: .listening)
      continuation?.yield(.partial("Tower N123AB"))
      finalTask?.cancel()
      finalTask = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(nanoseconds: 2_500_000_000)
        } catch {
          return
        }
        guard let self, self.status == .listening else { return }
        self.continuation?.yield(
          .segment(
            TranscriptSegment(
              text: "Tower N123AB cleared for takeoff",
              confidence: 0.96,
              sourceLanguageCode: "en",
              source: .liveATC
            ), speaker: nil))
        self.transition(to: .stopped)
      }
    }

    func stop() {
      finalTask?.cancel()
      finalTask = nil
      transition(to: .stopped)
    }

    private func transition(to newStatus: LiveTranscriptionStatus) {
      status = newStatus
      continuation?.yield(.status(newStatus))
    }
  }
#endif

private struct TranscriptBottomOffsetPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
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
    let mic = PortSnapshot(portType: .builtInMic, portName: "Built-in mic", uid: "preview-mic")
    return ContentView(
      routing: FakeAudioSessionRouting(
        currentRoute: RouteSnapshot(inputs: [mic]), availableInputs: [mic]),
      onboarding: OnboardingState(storage: PreviewCompletedOnboardingStorage()))
  }

  #Preview("Portrait") { previewCockpit() }

  #Preview("Landscape", traits: .landscapeLeft) { previewCockpit() }
#endif
