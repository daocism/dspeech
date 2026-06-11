@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

@MainActor
final class AppleSpeechLiveTranscriptionEngine: LiveTranscriptionEngine {
  private(set) var status: LiveTranscriptionStatus = .idle {
    didSet { emit(.status(status)) }
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

  // why: the segmenter cuts a decision window at a trailing-silence utterance edge
  // (>= minSilence after >= minSpeech of speech) or, failing that, at this
  // conservative max-window cap — keeping the prior 1.0 s ceiling as a strict upper
  // bound so this change is never a latency regression; sub-window tails fail open.
  private static let decisionWindowSeconds = 1.0
  private static let minSpeechSeconds = 0.25
  private static let minSilenceSeconds = 0.40
  private var continuation: AsyncStream<LiveTranscriptionEvent>.Continuation?

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
      self.continuation = continuation
      continuation.yield(.status(self.status))
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.stop()
        }
      }
    }
  }

  func start() async {
    guard !isStartupOrListening else { return }
    lifecycleGeneration += 1
    let generation = lifecycleGeneration
    status = .requestingPermission

    if !skipPermissionRequests {
      let speechAuthorized = await authorizer.requestSpeechAuthorization()
      guard isCurrentStartup(generation) else { return }
      guard speechAuthorized else {
        status = .failed("speech-permission-denied")
        return
      }

      let micAllowed = await authorizer.requestMicrophonePermission()
      guard isCurrentStartup(generation) else { return }
      guard micAllowed else {
        status = .failed("microphone-permission-denied")
        return
      }
    }

    guard let localeID = localeProvider() else {
      status = .failed("recognition-locale-unavailable")
      return
    }
    activeLocaleIdentifier = localeID
    let locale = Locale(identifier: localeID)
    // why: under the skip-permission test seam, tolerate a nil/unavailable recognizer so
    // the audio-capture path is still exercised (a Simulator may report it unavailable).
    let recognizer = SFSpeechRecognizer(locale: locale)
    if !skipPermissionRequests {
      guard let recognizer, recognizer.isAvailable else {
        guard isCurrentStartup(generation) else { return }
        status = .failed("recognizer-unavailable")
        return
      }
    }
    // why: requiresOnDeviceRecognition=true (privacy: local-only) errors immediately
    // if the locale's on-device dictation asset is not provisioned. Check up front
    // on every platform, including Simulator, so the normal LOCAL UI never falls
    // back to Apple's server Speech path.
    if requireOnDeviceModel {
      guard let recognizer, recognizer.supportsOnDeviceRecognition else {
        status = .failed("on-device-model-missing: \(localeID)")
        return
      }
    }
    recognizer?.defaultTaskHint = .dictation
    self.recognizer = recognizer
    guard arbiter.acquire(.liveTranscription) else {
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
      status = .failed("start-failed: \(error.localizedDescription)")
    }
  }

  func stop() {
    guard status == .listening || status == .ready || status == .requestingPermission else {
      return
    }
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
    try audioSession.configureForLiveRecording()
    try audioSession.setActive(true, options: [])
  }

  private func startEngine() throws {
    audioEngine = AVAudioEngine()
    configureCapturePipeline()
    try startCurrentAudioEngine()
    installEngineConfigurationObserver()
  }

  private func configureCapturePipeline() {
    if bufferGate != nil {
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
      throw LiveEngineError.invalidInputFormat
    }

    guard let audioContinuation = captureContinuation else {
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

    audioEngine.prepare()
    try audioEngine.start()
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
    } catch {
      _ = cleanup()
      status = .failed("engine-configuration-change-failed: \(error.localizedDescription)")
    }
  }

  // why: the recognition request/task is created separately from the audio engine so a
  // finished task (utterance final, or an on-device "no speech yet" timeout) can be
  // replaced WITHOUT tearing down the mic + tap — keeping live transcription continuous
  // instead of stopping after the first utterance or the first beat of silence.
  private func installRecognition(recognizer: SFSpeechRecognizer) {
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

    taskGeneration += 1
    let generation = taskGeneration
    let localePrefix = String(activeLocaleIdentifier.prefix(2))

    task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
      let failure: ASRFailure? = (error as NSError?).map {
        ASRFailure(domain: $0.domain, code: $0.code, message: $0.localizedDescription)
      }
      let event: LiveTranscriptionEvent?
      let isFinal: Bool
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
              sourceLanguageCode: localePrefix,
              source: .liveATC
            )
            event = .segment(segment)
          }
          isFinal = true
        } else {
          event = .partial(raw)
          isFinal = false
        }
      } else {
        event = nil
        isFinal = false
      }
      Task { @MainActor [weak self] in
        // why: ignore callbacks from a superseded task — restart/cleanup bump the
        // generation, so a cancelled task can't flip state for the live session.
        guard let self, self.taskGeneration == generation else { return }
        if let event { self.emit(event) }
        if isFinal || failure != nil {
          self.handleTermination(failure: failure)
        }
      }
    }
  }

  private func handleTermination(failure: ASRFailure?) {
    switch Self.terminationDecision(
      isListening: status == .listening,
      hasRecognizer: recognizer != nil,
      failure: failure
    ) {
    case .ignore:
      return
    case .fail(let message):
      // why: surface the real recognition error instead of swallowing it into a benign
      // .stopped — the #1 silent-failure that hid the F1 break from the user.
      cleanup()
      status = .failed(message)
    case .restart:
      guard let recognizer else { return }
      restartRecognition(recognizer: recognizer)
    }
  }

  // why: the restart-vs-surface decision is the most important business logic in the engine
  // (the F1 silent-failure fix). Extracted as a pure, synchronous function so it is unit-tested
  // directly with synthesized failures — the live recognitionTask callback that produces those
  // failures can't be driven deterministically in a test.
  static func terminationDecision(
    isListening: Bool,
    hasRecognizer: Bool,
    failure: ASRFailure?
  ) -> RecognitionTerminationDecision {
    guard isListening, hasRecognizer else { return .ignore }
    if let failure, !failure.isBenignNoSpeech {
      return .fail("asr-error: \(failure.domain)#\(failure.code) \(failure.message)")
    }
    return .restart
  }

  static func restartDecision(
    isListening: Bool,
    isAudioEngineRunning: Bool
  ) -> RecognitionRestartDecision {
    guard isListening else { return .ignore }
    guard isAudioEngineRunning else { return .fail("engine-died-before-restart") }
    return .restart
  }

  private func restartRecognition(recognizer: SFSpeechRecognizer) {
    switch Self.restartDecision(
      isListening: status == .listening, isAudioEngineRunning: audioEngine.isRunning)
    {
    case .ignore:
      return
    case .fail(let message):
      _ = cleanup()
      status = .failed(message)
      return
    case .restart:
      break
    }
    request?.endAudio()
    task?.cancel()
    task = nil
    request = nil
    installRecognition(recognizer: recognizer)
  }

  private func routeSamples(_ samples: [Float], sampleRate: Double) async throws
    -> PreTranscriptionRoutingDecision
  {
    guard let bufferGate else { return .transcribe(reason: .classifierUnavailable) }
    return try await bufferGate.route(samples: samples, sampleRate: sampleRate)
  }

  private func routeCaptured(_ captured: CapturedAudioBuffer) {
    guard let router else {
      request?.append(captured.buffer)
      return
    }
    // why: empty samples (non-float buffer) fail open to ASR while keeping FIFO
    // order with classified buffers ahead of and behind it in the serial router.
    router.submit(captured.buffer, samples: captured.samples, sampleRate: captured.sampleRate)
  }

  nonisolated static func monoFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
    guard buffer.format.commonFormat == .pcmFormatFloat32,
      let channelData = buffer.floatChannelData
    else {
      return nil
    }
    let frameLength = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard frameLength > 0, channelCount > 0 else { return nil }

    if channelCount == 1 {
      return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }

    var mono = [Float](repeating: 0, count: frameLength)
    let scale = 1.0 / Float(channelCount)
    if buffer.format.isInterleaved {
      // why: interleaved multichannel lives in a single pointer as L,R,L,R…; index
      // by frame*channelCount + channel, not per-channel pointers (which would be
      // out of bounds for interleaved external-interface input).
      let pointer = channelData[0]
      for frame in 0..<frameLength {
        var sum: Float = 0
        for channel in 0..<channelCount {
          sum += pointer[frame * channelCount + channel]
        }
        mono[frame] = sum * scale
      }
    } else {
      for channel in 0..<channelCount {
        let pointer = channelData[channel]
        for frame in 0..<frameLength {
          mono[frame] += pointer[frame]
        }
      }
      for frame in 0..<frameLength {
        mono[frame] *= scale
      }
    }
    return mono
  }

  private nonisolated static func averageConfidence(for transcription: SFTranscription) -> Double {
    let segments = transcription.segments
    guard !segments.isEmpty else { return 0.0 }
    let total = segments.reduce(0.0) { $0 + Double($1.confidence) }
    let avg = total / Double(segments.count)
    return avg > 0 ? avg : 0.5
  }

  @discardableResult
  private func cleanup() -> LiveEngineCleanupResult {
    lifecycleGeneration += 1
    taskGeneration += 1
    removeEngineConfigurationObserver()
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
    var deactivationFailure: String?
    if arbiter.release(.liveTranscription) {
      do {
        try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
      } catch {
        deactivationFailure = "audio-session-deactivation-failed: \(error.localizedDescription)"
      }
    }
    return LiveEngineCleanupResult(deactivationFailureSlug: deactivationFailure)
  }

  private func emit(_ event: LiveTranscriptionEvent) {
    continuation?.yield(event)
  }

  fileprivate nonisolated static func requestSpeechAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }

  fileprivate nonisolated static func requestMicrophonePermission() async -> Bool {
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
  #endif
}

@MainActor
protocol LiveSpeechAuthorizing {
  func requestSpeechAuthorization() async -> Bool
  func requestMicrophonePermission() async -> Bool
}

@MainActor
private struct AppleLiveSpeechAuthorizer: LiveSpeechAuthorizing {
  func requestSpeechAuthorization() async -> Bool {
    await AppleSpeechLiveTranscriptionEngine.requestSpeechAuthorization()
  }

  func requestMicrophonePermission() async -> Bool {
    await AppleSpeechLiveTranscriptionEngine.requestMicrophonePermission()
  }
}

@MainActor
protocol LiveAudioSessionManaging: AnyObject {
  func configureForLiveRecording() throws
  func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

@MainActor
final class SystemLiveAudioSession: LiveAudioSessionManaging {
  private let session: AVAudioSession

  init(session: AVAudioSession = .sharedInstance()) {
    self.session = session
  }

  func configureForLiveRecording() throws {
    try LiveAudioSessionRouting.configureRecordCategory(session)
  }

  func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
    try session.setActive(active, options: options)
  }
}

extension AVAudioPCMBuffer {
  // why: AVAudioEngine reuses the tap's buffer storage across callbacks, so any
  // buffer handed to async work must be deep-copied synchronously inside the tap or
  // its samples are overwritten before they are read.
  func dspeechDeepCopy() -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
      return nil
    }
    copy.frameLength = frameLength
    let frames = Int(frameLength)
    let channels = Int(format.channelCount)
    guard frames > 0, channels > 0 else { return copy }
    // why: interleaved buffers expose ONE channel pointer holding frames*channels
    // samples (L,R,L,R…); deinterleaved expose `channels` pointers of `frames` each.
    // Indexing per-channel on an interleaved buffer reads out of bounds and copies
    // only half the audio — silent corruption on external USB / line-in routes.
    let pointerCount = format.isInterleaved ? 1 : channels
    let elementsPerPointer = format.isInterleaved ? frames * channels : frames
    if let source = floatChannelData, let destination = copy.floatChannelData {
      for index in 0..<pointerCount {
        destination[index].update(from: source[index], count: elementsPerPointer)
      }
    } else if let source = int16ChannelData, let destination = copy.int16ChannelData {
      for index in 0..<pointerCount {
        destination[index].update(from: source[index], count: elementsPerPointer)
      }
    } else if let source = int32ChannelData, let destination = copy.int32ChannelData {
      for index in 0..<pointerCount {
        destination[index].update(from: source[index], count: elementsPerPointer)
      }
    } else {
      return nil
    }
    return copy
  }
}

private struct LiveEngineCleanupResult {
  let deactivationFailureSlug: String?
}

private enum LiveEngineError: LocalizedError {
  case invalidInputFormat
  case capturePipelineUnavailable
  case audioEngineNotRunningAfterConfigurationChange

  var errorDescription: String? {
    switch self {
    case .invalidInputFormat:
      return "invalid-input-format"
    case .capturePipelineUnavailable:
      return "capture-pipeline-unavailable"
    case .audioEngineNotRunningAfterConfigurationChange:
      return "audio-engine-not-running-after-configuration-change"
    }
  }
}

// why: the outcome of a recognition-task termination. `restart` keeps the mic+tap live and
// recycles the recognition request (normal final or a benign no-speech timeout); `fail` surfaces
// a real recognition fault; `ignore` is for callbacks that arrive when the session is no longer
// listening. Made a first-class type so the decision is testable in isolation.
enum RecognitionTerminationDecision: Equatable, Sendable {
  case ignore
  case restart
  case fail(String)
}

enum RecognitionRestartDecision: Equatable, Sendable {
  case ignore
  case restart
  case fail(String)
}

struct ASRFailure: Equatable, Sendable {
  let domain: String
  let code: Int
  let message: String

  // why: kAFAssistantErrorDomain code 1110 = "No speech detected" — a silence timeout,
  // not a fault; let the session restart and keep listening rather than show .failed.
  var isBenignNoSpeech: Bool {
    domain == "kAFAssistantErrorDomain" && code == 1110
  }
}
