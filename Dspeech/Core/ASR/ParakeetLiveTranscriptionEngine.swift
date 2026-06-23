import Foundation
import os

@MainActor
final class ParakeetLiveTranscriptionEngine: LiveTranscriptionEngine {
  private(set) var status: LiveTranscriptionStatus = .idle {
    didSet {
      emit(.status(status))
      switch status {
      case .idle:
        DspeechLog.engine.info("parakeet live transcription status=idle")
      case .requestingPermission:
        DspeechLog.engine.info("parakeet live transcription status=requesting-permission")
      case .ready:
        DspeechLog.engine.info("parakeet live transcription status=ready")
      case .listening:
        DspeechLog.engine.info("parakeet live transcription status=listening")
      case .stopped:
        DspeechLog.engine.info("parakeet live transcription status=stopped")
      case .failed(let slug):
        DspeechLog.engine.error(
          "parakeet live transcription status=failed slug=\(slug, privacy: .public)"
        )
      }
    }
  }

  private let transcriber: any ParakeetLiveStreaming
  private let installedModelFolderURL: @MainActor () -> URL?
  private let localeProvider: @MainActor () -> String?
  private let authorizer: any LiveSpeechAuthorizing
  private let audioConduit: LiveAudioCaptureConduit
  // why: kept for API parity with the WhisperKit/Apple engines and for the ContentView wiring,
  // but NOT consulted for speaker classification in this first round. The voice-filter gate needs
  // the EXACT samples of the finalized utterance; FluidAudio's streaming EOU callback yields only
  // text and exposes no per-utterance sample window (unlike WhisperKit, which holds the decode
  // window). Classifying on a wrong/partial buffer would be worse than not classifying, so the
  // emitted segment carries speaker: nil (fail-open, shown). Revisit when FluidAudio surfaces
  // utterance-boundary samples. See ADR-0012 + PLAN-2026-06-22 (Commit 2.2).
  private let bufferGate: (any SpeechAudioBufferGate)?

  // why: Parakeet EOU 120M is English-only (LibriSpeech-trained); the engine never runs on
  // non-English audio (locale gate in start()). Segments are always tagged "en". (ADR-0012.)
  private static let sourceLanguageCode = "en"
  // why: the streaming EOU callback yields text only — there is no confidence score in the
  // streaming path (the batch ASRResult.confidence is not reachable here). 0 = honest "unknown",
  // matching the project's honest-confidence stance, rather than fabricating a 1.0 that would
  // wrongly clear requiresVerification. (PLAN-2026-06-22 open question 1.)
  private static let unknownConfidence = 0.0

  private var lifecycleGeneration = 0
  private var eventContinuations: [UUID: AsyncStream<LiveTranscriptionEvent>.Continuation] = [:]
  private var consumeTask: Task<Void, Never>?
  private var latestPartialText: String?

  init(
    transcriber: any ParakeetLiveStreaming,
    installedModelFolderURL: @escaping @MainActor () -> URL?,
    localeProvider: @escaping @MainActor () -> String?,
    arbiter: AudioCaptureArbiter = .shared,
    audioSession: any LiveAudioSessionManaging = SystemLiveAudioSession(),
    authorizer: any LiveSpeechAuthorizing = AppleLiveSpeechAuthorizer(),
    bufferGate: (any SpeechAudioBufferGate)? = nil
  ) {
    self.transcriber = transcriber
    self.installedModelFolderURL = installedModelFolderURL
    self.localeProvider = localeProvider
    self.authorizer = authorizer
    self.audioConduit = LiveAudioCaptureConduit(arbiter: arbiter, audioSession: audioSession)
    self.bufferGate = bufferGate
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
        "parakeet live transcription start ignored reason=already-starting-or-listening"
      )
      return
    }
    DspeechLog.engine.info("parakeet live transcription start requested")
    lifecycleGeneration += 1
    let generation = lifecycleGeneration
    status = .requestingPermission

    let micAllowed = await authorizer.requestMicrophonePermission()
    guard isCurrentStartup(generation) else { return }
    guard micAllowed else {
      status = .failed("microphone-permission-denied")
      return
    }

    // why: English-only gate. A nil locale is allowed (no language set yet); any concrete
    // non-"en" locale must never reach the LibriSpeech-trained model (would be garbage /
    // hallucinations — CLAUDE.md hard rule #2). The UI also hides Parakeet for non-en locales,
    // but the engine enforces it defensively too. (ADR-0012.)
    let locale = localeProvider()
    if let locale, !locale.hasPrefix("en") {
      status = .failed("parakeet-requires-english-locale")
      return
    }

    guard let modelFolderURL = installedModelFolderURL() else {
      status = .failed("parakeet-model-not-installed")
      return
    }

    do {
      try await transcriber.loadModels(from: modelFolderURL)
      guard isCurrentStartup(generation) else {
        _ = cleanup()
        return
      }
      await installCallbacks(generation: generation)
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
          await self.consume(captured)
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
      DspeechLog.engine.debug("parakeet live transcription stop ignored reason=not-active")
      return
    }
    DspeechLog.engine.info("parakeet live transcription stop requested")
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

  // why: the FluidAudio callbacks are @Sendable and fire off the MainActor (on FluidAudio's
  // actor). They capture only `generation` (Sendable) and a weak self (a @MainActor class is
  // Sendable), and hop to the MainActor before touching any state — never reading engine state
  // directly off-actor. The generation guard drops stale callbacks after stop/cleanup.
  private func installCallbacks(generation: Int) async {
    await transcriber.setPartialCallback { [weak self] text in
      Task { @MainActor [weak self] in
        self?.handlePartial(text, generation: generation)
      }
    }
    await transcriber.setEouCallback { [weak self] text in
      Task { @MainActor [weak self] in
        self?.handleEndOfUtterance(text, generation: generation)
      }
    }
  }

  private func consume(_ captured: LiveCapturedAudioBuffer) async {
    guard status == .listening else { return }
    do {
      try await transcriber.appendSamples(captured.samples, sampleRate: captured.sampleRate)
      try await transcriber.processBufferedAudio()
    } catch {
      handleCaptureConduitFailure("parakeet-process-failed: \(error.localizedDescription)")
    }
  }

  private func handlePartial(_ text: String, generation: Int) {
    guard lifecycleGeneration == generation, status == .listening else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    latestPartialText = trimmed
    emit(.partial(trimmed))
  }

  private func handleEndOfUtterance(_ text: String, generation: Int) {
    guard lifecycleGeneration == generation, status == .listening else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    latestPartialText = nil
    guard !trimmed.isEmpty else { return }
    let segment = TranscriptSegment(
      text: trimmed,
      confidence: Self.unknownConfidence,
      sourceLanguageCode: Self.sourceLanguageCode,
      source: .liveATC
    )
    emit(.segment(segment, speaker: nil))
  }

  private func handleEngineConfigurationChange() {
    guard status == .listening else { return }
    DspeechLog.engine.info("parakeet live audio configuration-change rebuilt")
  }

  private func handleCaptureConduitFailure(_ slug: String) {
    guard status == .listening else { return }
    emitPendingPartialForFailure()
    _ = cleanup()
    status = .failed(slug)
  }

  // why: commit any in-flight partial as an interim-restart segment so spoken words aren't lost
  // when capture fails mid-utterance, mirroring the WhisperKit/Apple engines. confidence 0 +
  // isInterimRestartCommit flags it as needing verification, never silently persisted as final.
  private func emitPendingPartialForFailure() {
    guard let text = latestPartialText?.trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else { return }
    latestPartialText = nil
    emit(
      .segment(
        TranscriptSegment(
          text: text,
          confidence: 0,
          sourceLanguageCode: Self.sourceLanguageCode,
          source: .liveATC,
          isInterimRestartCommit: true
        ),
        speaker: nil
      ))
  }

  @discardableResult
  private func cleanup() -> LiveEngineCleanupResult {
    lifecycleGeneration += 1
    latestPartialText = nil
    let cleanupResult = audioConduit.stop()
    consumeTask?.cancel()
    consumeTask = nil
    // why: release the CoreML models off the MainActor. The generation bump above already
    // invalidates any stray callback, so a late cleanup completing is harmless.
    let transcriber = transcriber
    Task { await transcriber.cleanup() }
    return cleanupResult
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

  #if DEBUG
    // why: drive the engine into .listening with the FluidAudio callbacks installed but WITHOUT
    // real mic capture (headless simulator can't acquire audio). Tests then fire scripted
    // partial/EOU events through the fake transcriber, exactly like the WhisperKit engine's
    // primeListeningForTesting seam.
    func primeListeningForTesting(acquireCapture: Bool) async {
      lifecycleGeneration += 1
      let generation = lifecycleGeneration
      status = .requestingPermission
      await installCallbacks(generation: generation)
      if acquireCapture {
        _ = audioConduit.primeStartedForTesting(acquireCapture: true)
      }
      status = .listening
    }

    func simulateCaptureConduitFailureForTesting(_ slug: String) {
      handleCaptureConduitFailure(slug)
    }
  #endif
}
