@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

@MainActor
final class AppleSpeechLiveTranscriptionEngine: LiveTranscriptionEngine {
  private(set) var status: LiveTranscriptionStatus = .idle {
    didSet {
      emit(.status(status))
      switch status {
      case .idle:
        DspeechLog.engine.info("live transcription status=idle")
      case .requestingPermission:
        DspeechLog.engine.info("live transcription status=requesting-permission")
      case .ready:
        DspeechLog.engine.info("live transcription status=ready")
      case .listening:
        DspeechLog.engine.info("live transcription status=listening")
      case .stopped:
        DspeechLog.engine.info("live transcription status=stopped")
      case .failed(let slug):
        DspeechLog.engine.error(
          "live transcription status=failed slug=\(slug, privacy: .public)"
        )
      }
    }
  }

  private let localeProvider: @MainActor () -> String?
  // why: the configured aircraft callsign is the single highest-value contextual hint for the
  // on-device LM (a proper noun it has never seen). Read at each (re)install so a callsign the
  // user sets mid-session biases recognition without an app relaunch. Local-only, no privacy
  // impact (contextualStrings never leave the device).
  private let contextualCallSignProvider: @MainActor () -> String?
  private var activeLocaleIdentifier = "en-US"
  private let bufferGate: (any SpeechAudioBufferGate)?
  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var lifecycleGeneration = 0
  // why: monotonically bumped on every (re)install and on cleanup; a recognitionTask
  // callback only acts if its captured generation still matches, so a superseded or
  // cancelled task can never flip the live session's state.
  private var taskGeneration = 0
  private var router: UtteranceWindowRouter<AVAudioPCMBuffer>?
  private var audioEngine = AVAudioEngine()
  private var engineConfigurationObserver: NSObjectProtocol?
  private var recognizerAvailabilityDelegate: LiveRecognizerAvailabilityDelegate?
  private var recognitionCallbackContinuation: AsyncStream<RecognitionCallbackEvent>.Continuation?
  private var recognitionCallbackTask: Task<Void, Never>?
  private var replayTail = AudioReplayTail<AVAudioPCMBuffer>(
    maxDurationSeconds: 1.0,
    maxBufferCount: 96
  )
  private var restartLoopGuard = ASRRestartLoopGuard(maxRestartCount: 5, window: .seconds(10))
  private let restartClock = ContinuousClock()

  // why: the segmenter cuts a decision window at a trailing-silence utterance edge
  // (>= minSilence after >= minSpeech of speech) or, failing that, at this
  // conservative max-window cap — keeping the prior 1.0 s ceiling as a strict upper
  // bound so this change is never a latency regression; sub-window tails fail open.
  private static let decisionWindowSeconds = 1.0
  private static let minSpeechSeconds = 0.25
  private static let minSilenceSeconds = 0.40
  private var eventContinuations: [UUID: AsyncStream<LiveTranscriptionEvent>.Continuation] = [:]

  // why: the realtime audio tap must never touch @MainActor state synchronously —
  // doing so trips swift_task_isCurrentExecutor -> dispatch_assert_queue_fail on the
  // RealtimeMessenger thread (EXC_BREAKPOINT). The tap deep-copies each recycled
  // buffer and hands it to this ordered, Sendable stream; a single @MainActor
  // consumer drains it in FIFO capture order into the router/request.
  private var captureContinuation: AsyncStream<CapturedAudioBuffer>.Continuation?
  private var consumeTask: Task<Void, Never>?

  private struct CapturedAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let samples: [Float]
    let sampleRate: Double
  }

  // why: test seam — lets crash-repro tests reach the AVAudioEngine tap path even
  // when a host lacks an on-device dictation asset. It does NOT relax the live
  // recognition request's local-only policy; server Speech fallback is never used
  // by the main app path.
  private let requireOnDeviceModel: Bool
  // why: test seam — lets a Simulator test drive the audio-capture path without the
  // permission prompt (which would hang a non-UI test). Production always requests.
  private let skipPermissionRequests: Bool
  private let authorizer: any LiveSpeechAuthorizing
  private let arbiter: AudioCaptureArbiter
  private let audioSession: any LiveAudioSessionManaging

  nonisolated static var liveRequestsRequireOnDeviceRecognition: Bool { true }

  init(
    localeProvider: @escaping @MainActor () -> String? = { "en-US" },
    bufferGate: (any SpeechAudioBufferGate)? = nil,
    contextualCallSignProvider: @escaping @MainActor () -> String? = { nil },
    requireOnDeviceModel: Bool = true,
    skipPermissionRequests: Bool = false,
    authorizer: any LiveSpeechAuthorizing = AppleLiveSpeechAuthorizer(),
    arbiter: AudioCaptureArbiter = .shared,
    audioSession: any LiveAudioSessionManaging = SystemLiveAudioSession()
  ) {
    self.localeProvider = localeProvider
    self.bufferGate = bufferGate
    self.contextualCallSignProvider = contextualCallSignProvider
    self.requireOnDeviceModel = requireOnDeviceModel
    self.skipPermissionRequests = skipPermissionRequests
    self.authorizer = authorizer
    self.arbiter = arbiter
    self.audioSession = audioSession
  }

  func events() -> AsyncStream<LiveTranscriptionEvent> {
    AsyncStream<LiveTranscriptionEvent> { continuation in
      let id = UUID()
      self.eventContinuations[id] = continuation
      continuation.yield(.status(self.status))
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.removeEventSubscriber(id: id)
        }
      }
    }
  }

  func start() async {
    guard !isStartupOrListening else {
      DspeechLog.engine.debug(
        "live transcription start ignored reason=already-starting-or-listening"
      )
      return
    }
    DspeechLog.engine.info(
      "live transcription start requested onDeviceRequired=\(Self.liveRequestsRequireOnDeviceRecognition, privacy: .public)"
    )
    lifecycleGeneration += 1
    let generation = lifecycleGeneration
    status = .requestingPermission

    if !skipPermissionRequests {
      let speechAuthorized = await authorizer.requestSpeechAuthorization()
      guard isCurrentStartup(generation) else { return }
      guard speechAuthorized else {
        DspeechLog.engine.error("live transcription start failed slug=speech-permission-denied")
        status = .failed("speech-permission-denied")
        return
      }

      let micAllowed = await authorizer.requestMicrophonePermission()
      guard isCurrentStartup(generation) else { return }
      guard micAllowed else {
        DspeechLog.engine.error("live transcription start failed slug=microphone-permission-denied")
        status = .failed("microphone-permission-denied")
        return
      }
    }

    guard let localeID = localeProvider() else {
      DspeechLog.engine.error("live transcription start failed slug=recognition-locale-unavailable")
      status = .failed("recognition-locale-unavailable")
      return
    }
    activeLocaleIdentifier = localeID
    let locale = Locale(identifier: localeID)
    DspeechLog.engine.info(
      "live transcription configuring recognizer locale=\(localeID, privacy: .public) requireOnDeviceModel=\(self.requireOnDeviceModel, privacy: .public)"
    )
    let recognizer = SFSpeechRecognizer(locale: locale)
    if let recognizer {
      let firstRead = RecognizerCapabilityRead(
        isAvailable: recognizer.isAvailable,
        supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition
      )
      let secondRead: RecognizerCapabilityRead?
      if Self.startupGateDecision(
        firstRead: firstRead,
        secondRead: nil,
        requireOnDeviceModel: requireOnDeviceModel,
        skipPermissionRequests: skipPermissionRequests
      ) == .ready {
        secondRead = nil
      } else {
        await Task.yield()
        secondRead = RecognizerCapabilityRead(
          isAvailable: recognizer.isAvailable,
          supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition
        )
      }
      guard isCurrentStartup(generation) else { return }
      switch Self.startupGateDecision(
        firstRead: firstRead,
        secondRead: secondRead,
        requireOnDeviceModel: requireOnDeviceModel,
        skipPermissionRequests: skipPermissionRequests
      ) {
      case .ready:
        break
      case .fail(let slug):
        DspeechLog.engine.error(
          "live transcription start failed slug=\(slug, privacy: .public) locale=\(localeID, privacy: .public)"
        )
        if slug == "on-device-model-missing" {
          status = .failed("on-device-model-missing: \(localeID)")
        } else {
          status = .failed(slug)
        }
        return
      }
      let availabilityDelegate = LiveRecognizerAvailabilityDelegate(engine: self)
      recognizer.delegate = availabilityDelegate
      recognizerAvailabilityDelegate = availabilityDelegate
    } else {
      guard skipPermissionRequests && !requireOnDeviceModel else {
        let slug = skipPermissionRequests ? "on-device-model-missing" : "recognizer-unavailable"
        DspeechLog.engine.error(
          "live transcription start failed slug=\(slug, privacy: .public) locale=\(localeID, privacy: .public)"
        )
        if slug == "on-device-model-missing" {
          status = .failed("on-device-model-missing: \(localeID)")
        } else {
          status = .failed(slug)
        }
        return
      }
    }
    recognizer?.defaultTaskHint = .dictation
    self.recognizer = recognizer
    guard arbiter.acquire(.liveTranscription) else {
      DspeechLog.engine.error("live transcription start failed slug=capture-session-busy")
      status = .failed("capture-session-busy")
      return
    }

    do {
      guard isCurrentStartup(generation) else {
        _ = cleanup()
        return
      }
      try beginAudioSession()
      // why: bring up AVAudioEngine before attaching the recognition task.
      try startEngine()
      guard isCurrentStartup(generation) else {
        cleanup()
        return
      }
      if let recognizer { installRecognition(recognizer: recognizer) }
      status = .listening
    } catch {
      _ = cleanup()
      DspeechLog.engine.error(
        "live transcription start failed slug=start-failed error=\(error.localizedDescription)"
      )
      status = .failed("start-failed: \(error.localizedDescription)")
    }
  }

  func stop() {
    guard status == .listening || status == .ready || status == .requestingPermission else {
      DspeechLog.engine.debug("live transcription stop ignored reason=not-active")
      return
    }
    DspeechLog.engine.info("live transcription stop requested")
    let cleanupResult = cleanup()
    if let deactivationFailureSlug = cleanupResult.deactivationFailureSlug {
      status = .failed(deactivationFailureSlug)
    } else {
      status = .stopped
    }
  }

  private var isStartupOrListening: Bool {
    status == .requestingPermission || status == .listening
  }

  private func isCurrentStartup(_ generation: Int) -> Bool {
    lifecycleGeneration == generation && status == .requestingPermission
  }

  private func beginAudioSession() throws {
    DspeechLog.engine.info("live audio session configure requested")
    do {
      try audioSession.configureForLiveRecording()
      DspeechLog.engine.info("live audio session configure succeeded")
    } catch {
      DspeechLog.engine.error(
        "live audio session configure failed error=\(error.localizedDescription)"
      )
      throw error
    }

    DspeechLog.engine.info("live audio session activation requested")
    do {
      try audioSession.setActive(true, options: [])
      DspeechLog.engine.info("live audio session activation succeeded")
    } catch {
      DspeechLog.engine.error(
        "live audio session activation failed error=\(error.localizedDescription)"
      )
      throw error
    }
  }

  private func startEngine() throws {
    DspeechLog.engine.info("live audio engine start requested")
    audioEngine = AVAudioEngine()
    configureCapturePipeline()
    try startCurrentAudioEngine()
    installEngineConfigurationObserver()
    DspeechLog.engine.info("live audio engine started")
  }

  private func configureCapturePipeline() {
    if bufferGate != nil {
      DspeechLog.engine.info("live capture pipeline configured gate=voice-filter")
      // why: the gate routes through the nonisolated identifier, so the heavy
      // classifier work runs off @MainActor; the router groups buffers into a
      // decision window, classifies the whole window once, and serializes the
      // append/discard in capture order so a slow earlier window can't let a
      // later one overtake it into Apple Speech.
      let segmenter = EnergySilenceSegmenter(
        minSpeechSeconds: Self.minSpeechSeconds,
        minSilenceSeconds: Self.minSilenceSeconds,
        maxWindowSeconds: Self.decisionWindowSeconds
      )
      router = UtteranceWindowRouter<AVAudioPCMBuffer>(
        segmenter: segmenter,
        classify: { [weak self] samples, sampleRate in
          guard let self else { return .transcribe(reason: .classifierUnavailable) }
          return try await self.routeSamples(samples, sampleRate: sampleRate)
        },
        append: { [weak self] buffer in self?.request?.append(buffer) }
      )
    } else {
      router = nil
      DspeechLog.engine.info("live capture pipeline configured gate=none")
    }

    let (captureStream, audioContinuation) = AsyncStream<CapturedAudioBuffer>.makeStream(
      bufferingPolicy: .unbounded
    )
    captureContinuation = audioContinuation
    consumeTask = Task { @MainActor [weak self] in
      for await captured in captureStream {
        guard let self else { break }
        self.routeCaptured(captured)
      }
    }
  }

  private func startCurrentAudioEngine() throws {
    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)
    // why: on some device routes (mic not yet granted, mid route-change, certain
    // external interfaces) the input format reports 0 Hz / 0 channels; installing a
    // tap with it throws deep inside CoreAudio. Surface it as an explicit failure.
    guard recordingFormat.channelCount > 0, recordingFormat.sampleRate > 0 else {
      DspeechLog.engine.error(
        "live audio tap install failed slug=invalid-input-format sampleRate=\(recordingFormat.sampleRate, privacy: .public) channels=\(recordingFormat.channelCount, privacy: .public)"
      )
      throw LiveEngineError.invalidInputFormat
    }

    guard let audioContinuation = captureContinuation else {
      DspeechLog.engine.error("live audio tap install failed slug=capture-pipeline-unavailable")
      throw LiveEngineError.capturePipelineUnavailable
    }

    inputNode.removeTap(onBus: 0)
    // why: format:nil — the tap uses the input bus's OWN current format. Passing a
    // separately-read AVAudioFormat (recordingFormat) trips an NSException abort inside
    // AUGraphNodeBaseV3::CreateRecordingTap ("required condition is false:
    // format.sampleRate == hwFormat.sampleRate") when it doesn't match the live hardware
    // rate — which .measurement mode reconfigures, so the cached value is stale at
    // tap-build time. nil removes the mismatch; the guard above still fails-fast on a dead
    // (0 Hz / 0-channel) input. recordingFormat is kept only for that guard.
    //
    // why: the `@Sendable` on this block is LOAD-BEARING, not cosmetic. This type is
    // @MainActor, so a bare closure literal here inherits @MainActor isolation; when
    // AVFAudio invokes it on its realtime RealtimeMessenger thread, Swift asserts
    // swift_task_isCurrentExecutor(MainActor) → false → dispatch_assert_queue_fail
    // (EXC_BREAKPOINT) and the app crashes on the first captured buffer. `@Sendable`
    // forces the block nonisolated so it legally runs off-MainActor. It captures only
    // the Sendable continuation (never self / @MainActor state), deep-copies the
    // recycled buffer, and yields it in capture order for the @MainActor consumer.
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
      guard let copy = buffer.dspeechDeepCopy() else { return }
      let samples = Self.monoFloatSamples(from: copy) ?? []
      audioContinuation.yield(
        CapturedAudioBuffer(buffer: copy, samples: samples, sampleRate: copy.format.sampleRate)
      )
    }
    DspeechLog.engine.info(
      "live audio tap installed sampleRate=\(recordingFormat.sampleRate, privacy: .public) channels=\(recordingFormat.channelCount, privacy: .public)"
    )

    audioEngine.prepare()
    try audioEngine.start()
    DspeechLog.engine.info("live audio engine run loop started")
  }

  private func installEngineConfigurationObserver() {
    removeEngineConfigurationObserver()
    engineConfigurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: audioEngine,
      queue: nil
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.handleEngineConfigurationChange()
      }
    }
  }

  private func removeEngineConfigurationObserver() {
    if let engineConfigurationObserver {
      NotificationCenter.default.removeObserver(engineConfigurationObserver)
      self.engineConfigurationObserver = nil
    }
  }

  private func handleEngineConfigurationChange() {
    guard status == .listening else { return }
    DspeechLog.engine.info("live audio engine configuration-change rebuild requested")
    do {
      audioEngine.inputNode.removeTap(onBus: 0)
      try startCurrentAudioEngine()
      if let recognizer {
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        installRecognition(recognizer: recognizer)
      } else {
        taskGeneration += 1
      }
      guard audioEngine.isRunning else {
        throw LiveEngineError.audioEngineNotRunningAfterConfigurationChange
      }
      DspeechLog.engine.info("live audio engine configuration-change rebuild succeeded")
    } catch {
      _ = cleanup()
      DspeechLog.engine.error(
        "live audio engine configuration-change rebuild failed error=\(error.localizedDescription)"
      )
      status = .failed("engine-configuration-change-failed: \(error.localizedDescription)")
    }
  }

  // why: the recognition request/task is created separately from the audio engine so a
  // finished task (utterance final, or an on-device "no speech yet" timeout) can be
  // replaced WITHOUT tearing down the mic + tap — keeping live transcription continuous
  // instead of stopping after the first utterance or the first beat of silence.
  private func installRecognition(recognizer: SFSpeechRecognizer) {
    teardownRecognitionCallbackConduit()
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = Self.liveRequestsRequireOnDeviceRecognition
    request.taskHint = .dictation
    // why: bias the on-device LM toward ICAO phonetics + ATC phraseology it would
    // otherwise under-weight, plus the configured aircraft callsign (the highest-value
    // proper-noun hint); local-only, no privacy/network impact.
    request.contextualStrings = ATCContextualVocabulary.strings(
      callSign: contextualCallSignProvider())
    request.addsPunctuation = true
    self.request = request
    DspeechLog.engine.info(
      "recognition task installing locale=\(self.activeLocaleIdentifier, privacy: .public) onDevice=\(request.requiresOnDeviceRecognition, privacy: .public) contextualStringCount=\(request.contextualStrings.count, privacy: .public)"
    )

    taskGeneration += 1
    let generation = taskGeneration
    let sourceLanguageCode = Self.sourceLanguageCode(for: activeLocaleIdentifier)
    let callbackContinuation = installRecognitionCallbackConduit(generation: generation)

    task = recognizer.recognitionTask(with: request) { @Sendable result, error in
      let failure: ASRFailure? = (error as NSError?).map {
        ASRFailure(domain: $0.domain, code: $0.code, message: $0.localizedDescription)
      }
      if let failure {
        DspeechLog.engine.error(
          "recognition task callback failure domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)"
        )
      }
      let event: LiveTranscriptionEvent?
      let isFinal: Bool
      let hasResult = result != nil
      if let result {
        let raw = result.bestTranscription.formattedString
        if result.isFinal {
          let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
          if trimmed.isEmpty {
            event = nil
          } else {
            let confidence = Self.averageConfidence(for: result.bestTranscription)
            let segment = TranscriptSegment(
              text: trimmed,
              translatedText: nil,
              confidence: confidence,
              sourceLanguageCode: sourceLanguageCode,
              source: .liveATC
            )
            event = .segment(segment)
          }
          isFinal = true
          DspeechLog.engine.info("recognition task callback final=true")
        } else {
          event = .partial(raw)
          isFinal = false
        }
      } else {
        event = nil
        isFinal = false
      }
      callbackContinuation.yield(
        RecognitionCallbackEvent(
          generation: generation,
          event: event,
          isFinal: isFinal,
          failure: failure,
          hasResult: hasResult
        ))
    }
    for buffer in replayTail.buffers {
      request.append(buffer)
    }
  }

  private func installRecognitionCallbackConduit(
    generation: Int
  ) -> AsyncStream<RecognitionCallbackEvent>.Continuation {
    let (stream, continuation) = AsyncStream<RecognitionCallbackEvent>.makeStream(
      bufferingPolicy: .unbounded
    )
    recognitionCallbackContinuation = continuation
    recognitionCallbackTask = Task { @MainActor [weak self] in
      for await callback in stream {
        guard let self, self.taskGeneration == generation else { continue }
        self.handleRecognitionCallback(callback)
      }
    }
    return continuation
  }

  private func teardownRecognitionCallbackConduit() {
    recognitionCallbackContinuation?.finish()
    recognitionCallbackContinuation = nil
    recognitionCallbackTask?.cancel()
    recognitionCallbackTask = nil
  }

  private func handleRecognitionCallback(_ callback: RecognitionCallbackEvent) {
    guard taskGeneration == callback.generation else { return }
    if callback.hasResult || callback.event != nil {
      restartLoopGuard.recordResult()
    }
    if let event = callback.event { emit(event) }
    if callback.isFinal || callback.failure != nil {
      handleTermination(failure: callback.failure)
    }
  }

  private func handleTermination(failure: ASRFailure?) {
    switch Self.terminationDecision(
      isListening: status == .listening,
      hasRecognizer: recognizer != nil,
      failure: failure
    ) {
    case .ignore:
      DspeechLog.engine.info("recognition task termination decision=ignore")
      return
    case .fail(let message):
      DspeechLog.engine.error(
        "recognition task termination decision=fail slug=\(message, privacy: .public)"
      )
      // why: surface the real recognition error instead of swallowing it into a benign
      // .stopped — the #1 silent-failure that hid the F1 break from the user.
      cleanup()
      status = .failed(message)
    case .restart:
      DspeechLog.engine.info("recognition task termination decision=restart")
      switch restartLoopGuard.recordRestart(now: restartClock.now) {
      case .allow:
        break
      case .fail(let message):
        DspeechLog.engine.error(
          "recognition task termination decision=fail slug=\(message, privacy: .public)"
        )
        cleanup()
        status = .failed(message)
        return
      }
      guard let recognizer else { return }
      restartRecognition(recognizer: recognizer)
    }
  }

  private func restartRecognition(recognizer: SFSpeechRecognizer) {
    switch Self.restartDecision(
      isListening: status == .listening, isAudioEngineRunning: audioEngine.isRunning)
    {
    case .ignore:
      DspeechLog.engine.info("recognition task restart decision=ignore")
      return
    case .fail(let message):
      DspeechLog.engine.error(
        "recognition task restart decision=fail slug=\(message, privacy: .public)"
      )
      _ = cleanup()
      status = .failed(message)
      return
    case .restart:
      DspeechLog.engine.info("recognition task restart decision=restart")
      break
    }
    request?.endAudio()
    task?.cancel()
    task = nil
    request = nil
    installRecognition(recognizer: recognizer)
    DspeechLog.engine.info("recognition task restarted")
  }

  private func routeSamples(_ samples: [Float], sampleRate: Double) async throws
    -> PreTranscriptionRoutingDecision
  {
    guard let bufferGate else { return .transcribe(reason: .classifierUnavailable) }
    let decision = try await bufferGate.route(samples: samples, sampleRate: sampleRate)
    switch decision {
    case .transcribe(let reason):
      DspeechLog.engine.debug(
        "pre-asr routing decision=transcribe reason=\(String(describing: reason), privacy: .public)"
      )
    case .discard(let reason):
      DspeechLog.engine.debug(
        "pre-asr routing decision=discard reason=\(String(describing: reason), privacy: .public)"
      )
    }
    return decision
  }

  private func routeCaptured(_ captured: CapturedAudioBuffer) {
    replayTail.append(
      captured.buffer,
      sampleCount: Int(captured.buffer.frameLength),
      sampleRate: captured.sampleRate
    )
    guard let router else {
      request?.append(captured.buffer)
      return
    }
    // why: empty samples (non-float buffer) fail open to ASR while keeping FIFO
    // order with classified buffers ahead of and behind it in the serial router.
    router.submit(captured.buffer, samples: captured.samples, sampleRate: captured.sampleRate)
  }

  private nonisolated static func averageConfidence(for transcription: SFTranscription) -> Double {
    let segments = transcription.segments
    guard !segments.isEmpty else { return 0.0 }
    let total = segments.reduce(0.0) { $0 + Double($1.confidence) }
    return total / Double(segments.count)
  }

  @discardableResult
  private func cleanup() -> LiveEngineCleanupResult {
    DspeechLog.engine.info("live transcription cleanup started")
    lifecycleGeneration += 1
    taskGeneration += 1
    teardownRecognitionCallbackConduit()
    removeEngineConfigurationObserver()
    recognizer?.delegate = nil
    recognizerAvailabilityDelegate = nil
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    audioEngine.inputNode.removeTap(onBus: 0)
    // why: stop the producer first — finish the stream and cancel the consumer — so
    // no captured buffer is routed after teardown; then fail-open the router queue.
    captureContinuation?.finish()
    captureContinuation = nil
    consumeTask?.cancel()
    consumeTask = nil
    // why: finish() before nil-ing the request so any buffer still classifying
    // off-main can't append into an ended/released recognition request.
    router?.finish()
    router = nil
    request?.endAudio()
    task?.cancel()
    task = nil
    request = nil
    recognizer = nil
    replayTail.removeAll()
    restartLoopGuard.recordResult()
    var deactivationFailure: String?
    if arbiter.release(.liveTranscription) {
      DspeechLog.engine.info("live audio session deactivation requested")
      do {
        try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        DspeechLog.engine.info("live audio session deactivation succeeded")
      } catch {
        deactivationFailure = "audio-session-deactivation-failed: \(error.localizedDescription)"
        DspeechLog.engine.error(
          "live audio session deactivation failed error=\(error.localizedDescription)"
        )
      }
    }
    DspeechLog.engine.info("live transcription cleanup finished")
    return LiveEngineCleanupResult(deactivationFailureSlug: deactivationFailure)
  }

  private func emit(_ event: LiveTranscriptionEvent) {
    for continuation in eventContinuations.values {
      continuation.yield(event)
    }
  }

  private func removeEventSubscriber(id: UUID) {
    eventContinuations[id] = nil
    if eventContinuations.isEmpty {
      stop()
    }
  }

  func handleRecognizerAvailabilityChange(isAvailable: Bool) {
    guard status == .listening, !isAvailable else { return }
    DspeechLog.engine.error(
      "recognizer availability changed unavailable slug=recognizer-became-unavailable"
    )
    cleanup()
    status = .failed("recognizer-became-unavailable")
  }

  nonisolated static func requestSpeechAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }

  nonisolated static func requestMicrophonePermission() async -> Bool {
    await AVAudioApplication.requestRecordPermission()
  }

  #if DEBUG
    // why: test seam for cleanup/arbiter behavior without starting the process-global
    // AVAudioSession or depending on simulator microphone hardware. DEBUG-only so a
    // release build cannot fake a listening state.
    func primeListeningForTesting(acquireCapture: Bool) {
      if acquireCapture {
        _ = arbiter.acquire(.liveTranscription)
      }
      status = .listening
    }

    func simulateRecognizerAvailabilityChangeForTesting(_ isAvailable: Bool) {
      handleRecognizerAvailabilityChange(isAvailable: isAvailable)
    }

    func installRecognitionCallbackConduitForTesting(generation: Int) {
      taskGeneration = generation
      _ = installRecognitionCallbackConduit(generation: generation)
    }

    func emitRecognitionCallbackForTesting(
      generation: Int,
      event: LiveTranscriptionEvent?,
      isFinal: Bool,
      failure: ASRFailure? = nil,
      hasResult: Bool
    ) {
      recognitionCallbackContinuation?.yield(
        RecognitionCallbackEvent(
          generation: generation,
          event: event,
          isFinal: isFinal,
          failure: failure,
          hasResult: hasResult
        ))
    }

    func advanceTaskGenerationForTesting() {
      taskGeneration += 1
    }
  #endif
}
