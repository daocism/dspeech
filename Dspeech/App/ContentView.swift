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
  @State private var sidebarSelection: SidebarDestination? = .live
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        DspeechLog.persistence.error(
          "transcript store init failed error=\(String(describing: error), privacy: .private)"
        )
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
      // why: UI-test seam — seed the crew roster so the accessibility audit can sweep the
      // name+Re-record+delete rows on the installed-pack settings surface.
      if CommandLine.arguments.contains("-dspeech.uitest.seed-crew") {
        filter.seedCrewForTesting(count: 2)
      }
      let debugScriptedEngine: (any LiveTranscriptionEngine)? =
        RenderStableScriptedLiveTranscriptionEngine.makeFromLaunchArguments()
    #else
      let debugScriptedEngine: (any LiveTranscriptionEngine)? = nil
    #endif
    let whisperKitInstaller = WhisperKitModelInstaller()
    let parakeetInstaller = ParakeetModelInstaller()
    let resolvedEngine =
      engine
      ?? debugScriptedEngine
      ?? Self.makeLiveTranscriptionEngine(
        recognition: recognitionSettings,
        voiceFilter: filter,
        whisperKitInstaller: whisperKitInstaller,
        parakeetInstaller: parakeetInstaller
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
    whisperKitInstaller: WhisperKitModelInstaller,
    parakeetInstaller: ParakeetModelInstaller
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
    case .parakeet:
      guard parakeetInstaller.state.isInstalled,
        parakeetInstaller.installedModelFolderURL != nil
      else {
        DspeechLog.engine.error(
          "parakeet engine selected but local model is not installed; falling back to apple speech"
        )
        return makeAppleSpeechLiveTranscriptionEngine(
          recognition: recognition,
          voiceFilter: voiceFilter
        )
      }
      DspeechLog.engine.info("parakeet engine selected with installed local model")
      return ParakeetLiveTranscriptionEngine(
        transcriber: SystemParakeetStreamingAdapter(),
        installedModelFolderURL: { parakeetInstaller.installedModelFolderURL },
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
      // why: the on-device-locale readiness check is Apple-Speech-specific. WhisperKit and
      // Parakeet ship their own downloaded models and have no Apple per-language asset, so their
      // idle screen must NOT claim "no recognition languages" — that gate only applies to Apple.
      if recognition.engineChoice == .whisperKit || recognition.engineChoice == .parakeet {
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

  @ViewBuilder
  private func cockpitSurface(context: CockpitLayoutContext) -> some View {
    GeometryReader { geometry in
      let isLandscape = geometry.size.width > geometry.size.height
      let measure = context.contentMaxWidth

      ZStack(alignment: context.zStackAlignment) {
        LinearGradient(
          colors: [DspeechTheme.backgroundTop, DspeechTheme.backgroundBottom],
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
            openHistory: { presentHistory() },
            openSettings: { presentSettings() }
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
        .frame(maxWidth: measure, maxHeight: .infinity, alignment: .top)
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
          maxWidth: measure,
          canClearTranscriptView: canClearTranscriptView,
          error: liveViewModel.lastErrorMessage,
          clearTranscript: { showClearConfirmation = true }
        )
        FloatingStartControls(
          isLandscape: isLandscape,
          maxWidth: measure,
          showHints: showHints,
          isStopVisible: liveViewModel.canStopCurrentSession,
          // why: NEVER disable the control while permission is being requested — that left the pilot
          // stranded on a stuck "Requesting access" with no escape (2026-06-14). It shows Stop during
          // .requestingPermission (canStopCurrentSession), and a tap routes to stop()/abort.
          disabled: false
        ) {
          Task { await toggleListening() }
        }
      }
    }
  }

  var body: some View {
    Group {
      if horizontalSizeClass == .regular {
        iPadSplitLayout
      } else {
        cockpitSurface(context: .standalone)
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
    // why: warning haptic on the Clear-confirmation PRESENTATION (false->true edge of the state
    // flag), not on the destructive tap — it primes the pilot that a confirming action follows.
    // The closure form keeps dismissal (true->false) silent (D13, ADR 0013 rule 7).
    .sensoryFeedback(trigger: showClearConfirmation) { wasShown, isShown in
      isShown && !wasShown ? .warning : nil
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
      runTranscriptAutoCleanupIfEnabled()
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

  // why: E1/E2 — on regular width (iPad, iPad slide-over stays compact) the letterboxed phone
  // layout is replaced by a real NavigationSplitView: the sidebar is the navigation (Live /
  // History / Settings), the detail column hosts the cockpit or the re-housed History/Settings
  // views (NOT sheets). The sidebar is system chrome, so it gets automatic glass — no custom
  // glass is added (ADR 0013). The cockpit surface is the SAME `cockpitSurface` used on compact,
  // so there is one live-transcript implementation, not a duplicate.
  @ViewBuilder
  private var iPadSplitLayout: some View {
    NavigationSplitView {
      List(selection: $sidebarSelection) {
        Label(String(localized: "Live transcript"), systemImage: "waveform")
          .tag(SidebarDestination.live)
          .accessibilityIdentifier("sidebar-live")
        Label(String(localized: "Session history"), systemImage: "clock.arrow.circlepath")
          .tag(SidebarDestination.history)
          .accessibilityIdentifier("sidebar-history")
        Label(String(localized: "Settings"), systemImage: "gearshape")
          .tag(SidebarDestination.settings)
          .accessibilityIdentifier("sidebar-settings")
      }
      .navigationTitle("Dspeech")
    } detail: {
      switch sidebarSelection ?? .live {
      case .live:
        cockpitSurface(context: .splitDetail)
      case .history:
        historyColumn
      case .settings:
        settingsColumn
      }
    }
  }

  @ViewBuilder
  private var settingsColumn: some View {
    // why: same bindings/params the sheet passes; `.presentationSizing(.form)` is intentionally
    // absent here — that modifier is sheet-only, meaningless (and a no-op) in a detail column.
    SettingsView(
      privacy: privacy, recognition: recognition, translation: translation,
      audioSource: audioSource,
      translationFailure: liveViewModel.translationFailure,
      captureActive: liveViewModel.isListening,
      voiceFilter: voiceFilter,
      onVoiceFilterDisabled: { liveViewModel.unhideAllSuppressedSegments() }
    )
  }

  @ViewBuilder
  private var historyColumn: some View {
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

  // why: on regular width the History/Settings surfaces are sidebar-driven detail columns, so
  // "open" means selecting the sidebar destination, not presenting a sheet. On compact the sheet
  // path is unchanged (zero iPhone regression). Banners and the control-bar buttons both route
  // through here so every entry point adapts to the active layout.
  private func presentSettings() {
    if horizontalSizeClass == .regular {
      sidebarSelection = .settings
    } else {
      showSettings = true
    }
  }

  private func presentHistory() {
    if horizontalSizeClass == .regular {
      sidebarSelection = .history
    } else {
      showHistory = true
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

  // why: C8 — retention cleanup runs once per launch, only when the pilot opted in, and
  // before any session can start (the .task ordering), so the active flight is never in
  // range; a session started milliseconds ago can't be older than a 30-day cutoff anyway.
  private func runTranscriptAutoCleanupIfEnabled() {
    let retention = TranscriptRetentionSettings()
    guard retention.autoCleanupEnabled, let transcriptStore else { return }
    let cutoff = Date().addingTimeInterval(-TimeInterval(retention.window.days) * 86_400)
    do {
      let deleted = try transcriptStore.deleteSessions(olderThan: cutoff, excluding: nil as UUID?)
      if deleted > 0 {
        DspeechLog.persistence.info("auto-cleanup removed \(deleted) flight(s) past retention")
      }
    } catch {
      DspeechLog.persistence.error(
        "auto-cleanup failed: \(String(describing: error))")
    }
  }

  @ViewBuilder
  private func bannerStack() -> some View {
    // why: one GlassEffectContainer merges stacked banners into a single render pass
    // (ADR 0013 rule 4) — each banner is otherwise its own CABackdropLayer.
    GlassEffectContainer(spacing: 6) {
      bannerStackContent()
    }
  }

  @ViewBuilder
  private func bannerStackContent() -> some View {
    VStack(spacing: 6) {
      if let message = coordinator.routeBanner ?? coordinator.startBlockedMessage {
        RouteBanner(message: message, canStart: coordinator.canStart)
      }
      if coordinator.stoppedForBackgroundNotice {
        BackgroundStopNoticeBanner(
          onDismiss: { coordinator.dismissStoppedForBackgroundNotice() })
      }
      if let persistenceFailure = liveViewModel.persistenceFailure {
        PersistenceFailureBanner(
          message: persistenceFailure,
          onDismiss: { liveViewModel.dismissPersistenceFailure() })
      }
      if translation.enabled, let translationFailure = liveViewModel.translationFailure {
        TranslationFailureBanner(
          message: TranslationFailureText.userFacing(translationFailure),
          isUnavailable: liveViewModel.translationUnavailable,
          onOpenSettings: { presentSettings() })
      }
    }
  }

  @ViewBuilder
  private func filteredCountPill() -> some View {
    let count = liveViewModel.filteredTransmissions.count
    if count > 0 {
      HStack {
        FilteredCountPill(count: count, onReview: { showSuppressedReview = true })
        Spacer(minLength: 0)
      }
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
          // why: give the message its full intrinsic height so the long localized string
          // (de "Keine On-Device-Erkennungssprachen verfügbar.") wraps fully at AX sizes
          // instead of being vertically constrained between the Spacers.
          .fixedSize(horizontal: false, vertical: true)
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
            // why: drives the gated card entrance .transition on the card views — inert
            // without an animation bound to the card identity set. Same quiescence gate
            // as every decorative motion (the scripted-flow UI test is the canary).
            .animation(
              reduceMotion || DecorativeMotion.isDisabledForUITests
                ? nil : .snappy(duration: 0.25),
              value: displayedTransmissions.map(\.id)
            )
          }
          // why: floating controls (Start/mic, jump-to-live) overlay the scroll area;
          // a bottom content margin keeps transcript text from ever sliding UNDER them —
          // the audit's "potentially inaccessible text" class — at every scroll offset,
          // not just after the last card.
          .contentMargins(.bottom, 104, for: .scrollContent)
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
                .background(DspeechTheme.accent, in: Capsule())
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
    // why: D11 — the follow-live scroll is decorative motion; Reduce Motion jumps instead.
    if animated && !reduceMotion {
      withAnimation(.easeOut(duration: 0.18)) {
        proxy.scrollTo(TranscriptScrollAnchor.bottom, anchor: .bottom)
      }
    } else {
      proxy.scrollTo(TranscriptScrollAnchor.bottom, anchor: .bottom)
    }
  }

  // why: launch coachmark hints show ONLY in the pristine first-run idle state — never after the
  // first Start, never with any prior/visible content (the bubbles cover real controls, e.g. the
  // "Tap to start" bubble lands on Clear — an obscured-hit-region defect), and never at accessibility
  // text sizes (they clip beside the floating controls). The guard below encodes all those conditions.
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

// why: the three navigation destinations of the iPad split shell. `.live` is the default so a
// fresh regular-width launch lands on the cockpit; the control-bar buttons and banners drive the
// same selection so both the sidebar and in-cockpit affordances stay in sync.
enum SidebarDestination: Hashable {
  case live
  case history
  case settings
}

// why: E3 — the 720pt centered letterbox is gone. On compact the cockpit is full-bleed
// (.infinity, centered is moot). In the split detail the column IS the width constraint, so the
// content is capped to a comfortable reading measure and ANCHORED LEADING (topLeading ZStack)
// instead of centered — the transcript, Clear control, and Start button all share the same
// leading-anchored measure so they stay aligned.
enum CockpitLayoutContext {
  case standalone
  case splitDetail

  var contentMaxWidth: CGFloat {
    switch self {
    case .standalone: return .infinity
    case .splitDetail: return 760
    }
  }

  var zStackAlignment: Alignment {
    switch self {
    case .standalone: return .center
    case .splitDetail: return .topLeading
    }
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

  // why: the Canvas preview's own tiny stand-in for AudioSessionRouting — the real fake now lives in
  // the test target (never ships in the app). Static ready route, no mic hardware, empty event stream.
  private struct PreviewAudioSessionRouting: AudioSessionRouting {
    let currentRouteSnapshot: RouteSnapshot
    let availableInputSnapshots: [PortSnapshot]
    var routePreparationStatus: AudioRoutePreparationStatus { .ready }
    func routeChangeEvents() -> AsyncStream<RouteChangeEvent> {
      AsyncStream { $0.finish() }
    }
    func requestRecordPermission() async -> Bool { true }
    func setPreferredInput(uid: String) throws {}
  }

  @MainActor private func previewCockpit() -> ContentView {
    let mic = PortSnapshot(portType: .builtInMic, portName: "Built-in mic", uid: "preview-mic")
    return ContentView(
      routing: PreviewAudioSessionRouting(
        currentRouteSnapshot: RouteSnapshot(inputs: [mic]), availableInputSnapshots: [mic]),
      onboarding: OnboardingState(storage: PreviewCompletedOnboardingStorage()))
  }

  #Preview("Portrait") { previewCockpit() }

  #Preview("Landscape", traits: .landscapeLeft) { previewCockpit() }
#endif
