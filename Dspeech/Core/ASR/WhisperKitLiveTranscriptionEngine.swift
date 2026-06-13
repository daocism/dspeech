@preconcurrency import AVFoundation
import Foundation

struct WhisperLiveSegment: Equatable, Sendable {
  let text: String
  let startSeconds: Double
  let endSeconds: Double
  let avgLogProb: Double
}

protocol WhisperLiveTranscribing: Sendable {
  func loadModel(folderURL: URL) async throws
  func transcribe(samples: [Float], languageCode: String?) async throws -> [WhisperLiveSegment]
}

@MainActor
final class WhisperKitLiveTranscriptionEngine: LiveTranscriptionEngine {
  private(set) var status: LiveTranscriptionStatus = .idle {
    didSet {
      emit(.status(status))
      switch status {
      case .idle:
        DspeechLog.engine.info("whisperkit live transcription status=idle")
      case .requestingPermission:
        DspeechLog.engine.info("whisperkit live transcription status=requesting-permission")
      case .ready:
        DspeechLog.engine.info("whisperkit live transcription status=ready")
      case .listening:
        DspeechLog.engine.info("whisperkit live transcription status=listening")
      case .stopped:
        DspeechLog.engine.info("whisperkit live transcription status=stopped")
      case .failed(let slug):
        DspeechLog.engine.error(
          "whisperkit live transcription status=failed slug=\(slug, privacy: .public)"
        )
      }
    }
  }

  private let transcriber: any WhisperLiveTranscribing
  private let installedModelFolderURL: @MainActor () -> URL?
  private let localeProvider: @MainActor () -> String?
  private let authorizer: any LiveSpeechAuthorizing
  private let audioConduit: LiveAudioCaptureConduit
  // why: WhisperKit is multilingual and treats the locale purely as an OPTIONAL
  // language hint (nil → auto-detect). Unlike Apple Speech it ships no per-language
  // on-device asset, so it must run even when no Apple dictation locale exists.
  private var activeLocaleIdentifier: String?
  private static let deviceLanguageCode = Locale.current.language.languageCode?.identifier ?? "en"
  private var lifecycleGeneration = 0
  private var eventContinuations: [UUID: AsyncStream<LiveTranscriptionEvent>.Continuation] = [:]
  private var consumeTask: Task<Void, Never>?
  private var decodeTask: Task<Void, Never>?
  private var isDecodeInFlight = false
  private var pendingFinalDecode = false
  private var pendingRecognitionPartial = PendingRecognitionPartial()
  private var windowSamples: [Float] = []
  private var windowStartAbsoluteSample: Int64 = 0
  private var lastDecodeRequestAbsoluteSample: Int64 = 0
  private var segmenter = WhisperKitLiveTranscriptionEngine.makeSegmenter()

  init(
    transcriber: any WhisperLiveTranscribing,
    installedModelFolderURL: @escaping @MainActor () -> URL?,
    localeProvider: @escaping @MainActor () -> String?,
    arbiter: AudioCaptureArbiter = .shared,
    audioSession: any LiveAudioSessionManaging = SystemLiveAudioSession(),
    authorizer: any LiveSpeechAuthorizing = AppleLiveSpeechAuthorizer()
  ) {
    self.transcriber = transcriber
    self.installedModelFolderURL = installedModelFolderURL
    self.localeProvider = localeProvider
    self.authorizer = authorizer
    self.audioConduit = LiveAudioCaptureConduit(arbiter: arbiter, audioSession: audioSession)
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
        "whisperkit live transcription start ignored reason=already-starting-or-listening"
      )
      return
    }
    DspeechLog.engine.info("whisperkit live transcription start requested")
    lifecycleGeneration += 1
    let generation = lifecycleGeneration
    status = .requestingPermission

    let micAllowed = await authorizer.requestMicrophonePermission()
    guard isCurrentStartup(generation) else { return }
    guard micAllowed else {
      status = .failed("microphone-permission-denied")
      return
    }

    guard let modelFolderURL = installedModelFolderURL() else {
      status = .failed("whisperkit-model-not-installed")
      return
    }
    // why: a nil locale is NOT a failure for WhisperKit — it means "no language
    // hint, auto-detect". The provider returns nil whenever the user has no Apple
    // on-device dictation locale; blocking here made the selectable WhisperKit
    // engine unusable in exactly that case (its whole reason to exist).
    activeLocaleIdentifier = localeProvider()

    do {
      try await transcriber.loadModel(folderURL: modelFolderURL)
      guard isCurrentStartup(generation) else {
        _ = cleanup()
        return
      }
      let captureStream = try audioConduit.start(
        onConfigurationChange: { [weak self] in
          self?.handleEngineConfigurationChange()
        },
        onFailure: { [weak self] slug in
          self?.handleCaptureConduitFailure(slug)
        }
      )
      consumeTask = Task { @MainActor [weak self] in
        for await captured in captureStream {
          guard let self else { break }
          self.consume(captured)
        }
      }
      guard isCurrentStartup(generation) else {
        _ = cleanup()
        return
      }
      status = .listening
    } catch {
      _ = cleanup()
      let slug =
        error.localizedDescription == "capture-session-busy"
        ? "capture-session-busy"
        : "start-failed: \(error.localizedDescription)"
      status = .failed(slug)
    }
  }

  func stop() {
    guard status == .listening || status == .ready || status == .requestingPermission else {
      DspeechLog.engine.debug("whisperkit live transcription stop ignored reason=not-active")
      return
    }
    DspeechLog.engine.info("whisperkit live transcription stop requested")
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

  private func handleEngineConfigurationChange() {
    guard status == .listening else { return }
    DspeechLog.engine.info("whisperkit live audio configuration-change rebuilt")
  }

  private func handleCaptureConduitFailure(_ slug: String) {
    guard status == .listening else { return }
    emitPendingPartialForFailure()
    _ = cleanup()
    status = .failed(slug)
  }

  private func consume(_ captured: LiveCapturedAudioBuffer) {
    do {
      let samples = try Self.whisperSamples(from: captured.buffer)
      appendWhisperSamples(samples)
    } catch {
      handleCaptureConduitFailure("audio-resample-failed: \(error.localizedDescription)")
    }
  }

  private func appendWhisperSamples(_ samples: [Float]) {
    guard status == .listening, !samples.isEmpty else { return }
    windowSamples.append(contentsOf: samples)
    switch segmenter.update(block: samples, sampleRate: Self.targetSampleRate) {
    case .accumulate:
      maybeSchedulePartialDecode()
    case .cutAfterSilence, .cutAtMaxWindow:
      scheduleDecode(.final)
    }
  }

  private func maybeSchedulePartialDecode() {
    let currentEnd = windowStartAbsoluteSample + Int64(windowSamples.count)
    let newSampleCount = currentEnd - lastDecodeRequestAbsoluteSample
    guard newSampleCount >= Self.minNewAudioSampleCount else { return }
    scheduleDecode(.partial)
  }

  private func scheduleDecode(_ purpose: WhisperDecodePurpose) {
    guard status == .listening, !windowSamples.isEmpty else { return }
    guard !isDecodeInFlight else {
      if purpose == .final { pendingFinalDecode = true }
      return
    }
    isDecodeInFlight = true
    if purpose == .final { pendingFinalDecode = false }
    let snapshot = WhisperDecodeSnapshot(
      purpose: purpose,
      samples: windowSamples,
      windowStartAbsoluteSample: windowStartAbsoluteSample,
      windowSampleCount: windowSamples.count,
      localeIdentifier: activeLocaleIdentifier
    )
    lastDecodeRequestAbsoluteSample =
      snapshot.windowStartAbsoluteSample + Int64(snapshot.windowSampleCount)
    let transcriber = transcriber
    let generation = lifecycleGeneration
    let languageCode = Self.sourceLanguageCode(for: snapshot.localeIdentifier)
    decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
      let result: Result<[WhisperLiveSegment], Error>
      do {
        result = .success(
          try await transcriber.transcribe(samples: snapshot.samples, languageCode: languageCode)
        )
      } catch {
        result = .failure(error)
      }
      await MainActor.run { [weak self] in
        self?.handleDecodeCompletion(result, snapshot: snapshot, generation: generation)
      }
    }
  }

  private func handleDecodeCompletion(
    _ result: Result<[WhisperLiveSegment], Error>,
    snapshot: WhisperDecodeSnapshot,
    generation: Int
  ) {
    guard lifecycleGeneration == generation else { return }
    isDecodeInFlight = false
    decodeTask = nil
    switch result {
    case .success(let segments):
      switch snapshot.purpose {
      case .partial:
        emitPartial(segments)
      case .final:
        emitFinal(segments, snapshot: snapshot)
      }
    case .failure(let error):
      emitPendingPartialForFailure()
      _ = cleanup()
      status = .failed("whisperkit-decode-failed: \(error.localizedDescription)")
      return
    }

    guard status == .listening else { return }
    if pendingFinalDecode {
      scheduleDecode(.final)
    } else {
      maybeSchedulePartialDecode()
    }
  }

  private func emitPartial(_ segments: [WhisperLiveSegment]) {
    guard let text = Self.combinedText(from: segments) else { return }
    pendingRecognitionPartial.record(event: .partial(text), isFinal: false)
    emit(.partial(text))
  }

  private func emitFinal(_ segments: [WhisperLiveSegment], snapshot: WhisperDecodeSnapshot) {
    defer {
      pendingRecognitionPartial.clear()
      advanceWindow(dropping: snapshot.windowSampleCount)
    }
    guard let text = Self.combinedText(from: segments) else { return }
    let segment = TranscriptSegment(
      text: text,
      confidence: Self.confidence(from: segments),
      sourceLanguageCode: Self.sourceLanguageCode(for: snapshot.localeIdentifier)
        ?? Self.deviceLanguageCode,
      source: .liveATC
    )
    emit(.segment(segment))
  }

  private func advanceWindow(dropping sampleCount: Int) {
    let dropped = min(sampleCount, windowSamples.count)
    if dropped > 0 {
      windowSamples.removeFirst(dropped)
      windowStartAbsoluteSample += Int64(dropped)
    }
    lastDecodeRequestAbsoluteSample = windowStartAbsoluteSample + Int64(windowSamples.count)
    segmenter.reset()
    if !windowSamples.isEmpty {
      _ = segmenter.update(block: windowSamples, sampleRate: Self.targetSampleRate)
    }
  }

  @discardableResult
  private func cleanup() -> LiveEngineCleanupResult {
    lifecycleGeneration += 1
    decodeTask?.cancel()
    decodeTask = nil
    isDecodeInFlight = false
    pendingFinalDecode = false
    pendingRecognitionPartial.clear()
    windowSamples.removeAll()
    windowStartAbsoluteSample = 0
    lastDecodeRequestAbsoluteSample = 0
    segmenter.reset()
    let cleanupResult = audioConduit.stop()
    consumeTask?.cancel()
    consumeTask = nil
    return cleanupResult
  }

  private func emitPendingPartialForFailure() {
    guard let text = pendingRecognitionPartial.takeTrimmedText() else { return }
    emit(.segment(Self.interimRestartSegment(text: text, localeIdentifier: activeLocaleIdentifier)))
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

  static func confidence(fromAverageLogProb value: Double) -> Double {
    min(1, max(0, exp(value)))
  }

  static func confidence(from segments: [WhisperLiveSegment]) -> Double {
    guard !segments.isEmpty else { return 0 }
    let mean = segments.reduce(0.0) { $0 + exp($1.avgLogProb) } / Double(segments.count)
    return min(1, max(0, mean))
  }

  private static func combinedText(from segments: [WhisperLiveSegment]) -> String? {
    let text =
      segments
      .sorted { $0.startSeconds < $1.startSeconds }
      .map { cleanSegmentText($0.text) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  private static func cleanSegmentText(_ raw: String) -> String {
    var text = raw
    while let open = text.range(of: "<|"),
      let close = text.range(of: "|>", range: open.upperBound..<text.endIndex)
    {
      text.removeSubrange(open.lowerBound..<close.upperBound)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // why: nil locale → nil language code (whisper auto-detects); callers that need a
  // concrete language tag for a stored/displayed segment fall back to the device language.
  private static func sourceLanguageCode(for localeIdentifier: String?) -> String? {
    guard let localeIdentifier else { return nil }
    return Locale(identifier: localeIdentifier).language.languageCode?.identifier
      ?? localeIdentifier
  }

  private static func interimRestartSegment(
    text: String,
    localeIdentifier: String?
  ) -> TranscriptSegment {
    TranscriptSegment(
      text: text,
      confidence: 0,
      sourceLanguageCode: sourceLanguageCode(for: localeIdentifier) ?? deviceLanguageCode,
      source: .liveATC,
      isInterimRestartCommit: true
    )
  }

  private static func makeSegmenter() -> EnergySilenceSegmenter {
    EnergySilenceSegmenter(
      minSpeechSeconds: minSpeechSeconds,
      minSilenceSeconds: trailingSilenceFinalizeSeconds,
      maxWindowSeconds: maxWindowSeconds
    )
  }

  private static func whisperSamples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
    guard buffer.frameLength > 0 else { return [] }
    let outputFormat = try whisperAudioFormat()
    if buffer.format.commonFormat == .pcmFormatFloat32,
      buffer.format.sampleRate == targetSampleRate,
      buffer.format.channelCount == 1,
      let samples = LiveAudioCaptureConduit.monoFloatSamples(from: buffer)
    {
      return samples
    }
    guard let converter = AVAudioConverter(from: buffer.format, to: outputFormat) else {
      throw WhisperLiveEngineError.resamplerUnavailable
    }
    var capacity =
      converter.outputFormat.sampleRate * Double(buffer.frameLength)
      / converter.inputFormat.sampleRate
    if capacity.truncatingRemainder(dividingBy: 1) != 0 {
      capacity = max(1, capacity.rounded(.up))
    }
    guard
      let converted = AVAudioPCMBuffer(
        pcmFormat: converter.outputFormat,
        frameCapacity: AVAudioFrameCount(capacity)
      )
    else {
      throw WhisperLiveEngineError.resampleBufferUnavailable
    }
    let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
      outStatus.pointee = .haveData
      return buffer
    }
    var error: NSError?
    let status = converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
    if status == .error {
      throw error ?? WhisperLiveEngineError.resampleFailed
    }
    guard let samples = LiveAudioCaptureConduit.monoFloatSamples(from: converted) else {
      throw WhisperLiveEngineError.resampleOutputUnavailable
    }
    return samples
  }

  private static func whisperAudioFormat() throws -> AVAudioFormat {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
      )
    else {
      throw WhisperLiveEngineError.resampleFormatUnavailable
    }
    return format
  }

  private static let targetSampleRate = 16_000.0
  private static let minNewAudioSeconds = 1.0
  private static let minNewAudioSampleCount = Int64(targetSampleRate * minNewAudioSeconds)
  private static let minSpeechSeconds = 0.25
  private static let trailingSilenceFinalizeSeconds = 1.0
  private static let maxWindowSeconds = 28.0

  #if DEBUG
    func primeListeningForTesting(acquireCapture: Bool) {
      activeLocaleIdentifier = localeProvider() ?? activeLocaleIdentifier
      if acquireCapture {
        _ = audioConduit.primeStartedForTesting(acquireCapture: true)
      }
      status = .listening
    }

    func appendSamplesForTesting(_ samples: [Float], sampleRate: Double) {
      guard sampleRate == Self.targetSampleRate else { return }
      appendWhisperSamples(samples)
    }

    func simulateCaptureConduitFailureForTesting(_ slug: String) {
      handleCaptureConduitFailure(slug)
    }
  #endif
}

private enum WhisperDecodePurpose: Sendable {
  case partial
  case final
}

private struct WhisperDecodeSnapshot: Sendable {
  let purpose: WhisperDecodePurpose
  let samples: [Float]
  let windowStartAbsoluteSample: Int64
  let windowSampleCount: Int
  let localeIdentifier: String?
}

private enum WhisperLiveEngineError: LocalizedError {
  case resampleFormatUnavailable
  case resamplerUnavailable
  case resampleBufferUnavailable
  case resampleOutputUnavailable
  case resampleFailed

  var errorDescription: String? {
    switch self {
    case .resampleFormatUnavailable:
      "resample-format-unavailable"
    case .resamplerUnavailable:
      "resampler-unavailable"
    case .resampleBufferUnavailable:
      "resample-buffer-unavailable"
    case .resampleOutputUnavailable:
      "resample-output-unavailable"
    case .resampleFailed:
      "resample-failed"
    }
  }
}
