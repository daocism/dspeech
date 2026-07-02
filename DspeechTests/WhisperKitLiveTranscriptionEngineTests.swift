@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import Dspeech

@MainActor
struct WhisperKitLiveTranscriptionEngineTests {
  @Test func startWithoutInstalledModelFailsBeforeLoadingTranscriber() async {
    let authorizer = SpyWhisperAuthorizer(microphoneAllowed: true)
    let transcriber = FakeWhisperLiveTranscriber { samples, _ in
      [
        WhisperLiveSegment(
          text: "\(samples.count)",
          startSeconds: 0,
          endSeconds: Double(samples.count) / 16_000,
          avgLogProb: 0
        )
      ]
    }
    let engine = WhisperKitLiveTranscriptionEngine(
      transcriber: transcriber,
      installedModelFolderURL: { nil },
      localeProvider: { "fr-FR" },
      authorizer: authorizer
    )

    await engine.start()

    #expect(engine.status == .failed("whisperkit-model-not-installed"))
    #expect(authorizer.speechRequestCount == 0)
    #expect(authorizer.microphoneRequestCount == 1)
    #expect(await transcriber.loadedFolders().isEmpty)
  }

  // why: regression — WhisperKit must get PAST start() with a nil locale (no Apple
  // on-device dictation language present) instead of failing with
  // "recognition-locale-unavailable". start() loads the model right after accepting the
  // locale and before acquiring real audio; on a headless simulator the real capture step
  // then fails, so we assert the engine reached model loading and never produced the
  // locale failure — the exact defect the real-audio run surfaced that green tests missed.
  @Test func startWithNilLocaleGetsPastLocaleGateAndLoadsModel() async {
    let transcriber = FakeWhisperLiveTranscriber { _, _ in [] }
    let engine = WhisperKitLiveTranscriptionEngine(
      transcriber: transcriber,
      installedModelFolderURL: { URL(fileURLWithPath: "/tmp/local-whisper", isDirectory: true) },
      localeProvider: { nil },
      audioSession: SpyWhisperAudioSession(),
      authorizer: SpyWhisperAuthorizer(microphoneAllowed: true)
    )

    await engine.start()

    #expect(await transcriber.loadedFolders().count == 1)
    #expect(engine.status != .failed("recognition-locale-unavailable"))
  }

  // why: with a nil locale WhisperKit decodes with NO language hint (auto-detect), and the
  // stored segment still carries a concrete language tag via the device-language fallback.
  @Test func nilLocaleDecodesWithoutLanguageHintAndFallsBackToDeviceLanguage() async {
    let transcriber = FakeWhisperLiveTranscriber { samples, _ in
      [
        WhisperLiveSegment(
          text: "bonjour",
          startSeconds: 0,
          endSeconds: Double(samples.count) / 16_000,
          avgLogProb: log(0.7)
        )
      ]
    }
    let engine = WhisperKitLiveTranscriptionEngine(
      transcriber: transcriber,
      installedModelFolderURL: { URL(fileURLWithPath: "/tmp/local-whisper", isDirectory: true) },
      localeProvider: { nil },
      authorizer: SpyWhisperAuthorizer(microphoneAllowed: true)
    )
    let recorder = WhisperEventRecorder()
    let collector = collect(engine.events(), into: recorder)
    engine.primeListeningForTesting(acquireCapture: false)

    engine.appendSamplesForTesting(Self.samples(count: 16_000, value: 0.2), sampleRate: 16_000)
    engine.appendSamplesForTesting(Self.samples(count: 16_000, value: 0), sampleRate: 16_000)
    #expect(await waitForEvent({ await recorder.segments().count == 1 }))
    let decodeLanguages = await transcriber.decodeRequests().map(\.languageCode)
    #expect(
      decodeLanguages.allSatisfy { $0 == nil }, "nil locale must decode with no language hint")
    // the stored segment still carries a concrete language tag (device fallback)
    #expect(await recorder.segments().first?.sourceLanguageCode.isEmpty == false)
    collector.cancel()
    engine.stop()
  }

  // why: one mic press, several spoken transmissions separated by realistic (non-zero) gaps, must
  // finalize as SEVERAL segments, not one rolling "dictaphone" line. The gaps carry a real device
  // noise floor (RMS 0.03), which a fixed-threshold segmenter mis-reads as continuous speech (no
  // in-stream cuts at all); the adaptive segmenter closes each utterance at its trailing gap.
  // Perfect-silence (value:0) fixtures cannot exercise this.
  @Test func continuousMultiUtteranceStreamWithRealisticGapsSegmentsEachTransmission() async {
    let transcriber = FakeWhisperLiveTranscriber { samples, _ in
      guard samples.contains(where: { $0 > 0.1 }) else { return [] }
      return [
        WhisperLiveSegment(
          text: "transmission",
          startSeconds: 0,
          endSeconds: Double(samples.count) / 16_000,
          avgLogProb: log(0.8)
        )
      ]
    }
    let engine = WhisperKitLiveTranscriptionEngine(
      transcriber: transcriber,
      installedModelFolderURL: { URL(fileURLWithPath: "/tmp/local-whisper", isDirectory: true) },
      localeProvider: { "en-US" },
      authorizer: SpyWhisperAuthorizer(microphoneAllowed: true)
    )
    let recorder = WhisperEventRecorder()
    let collector = collect(engine.events(), into: recorder)
    engine.primeListeningForTesting(acquireCapture: false)

    // 3 transmissions (1.0s speech each) separated by 1.25s gaps at a realistic mic noise floor.
    // Paced like a real flight (each transmission finalizes during the gap before the next
    // arrives), which is exactly when the decode completes and the window closes.
    for utterance in 1...3 {
      engine.appendSamplesForTesting(Self.samples(count: 16_000, value: 0.3), sampleRate: 16_000)
      engine.appendSamplesForTesting(Self.samples(count: 20_000, value: 0.03), sampleRate: 16_000)
      #expect(
        await waitForEvent({ await recorder.segments().count == utterance }),
        "transmission \(utterance) must finalize as its own segment before the next arrives")
    }
    collector.cancel()
    engine.stop()
  }

  @Test func scriptedSamplesEmitGrowingPartialsThenFinalizeAndAdvanceWindow() async {
    let transcriber = FakeWhisperLiveTranscriber { samples, _ in
      let text =
        if samples.contains(where: { $0 > 0.35 }) {
          "charlie"
        } else if samples.count >= 32_000 {
          "alpha bravo"
        } else {
          "alpha"
        }
      return [
        WhisperLiveSegment(
          text: text,
          startSeconds: 0,
          endSeconds: Double(samples.count) / 16_000,
          avgLogProb: log(0.64)
        )
      ]
    }
    let engine = WhisperKitLiveTranscriptionEngine(
      transcriber: transcriber,
      installedModelFolderURL: { URL(fileURLWithPath: "/tmp/local-whisper", isDirectory: true) },
      localeProvider: { "en-US" },
      authorizer: SpyWhisperAuthorizer(microphoneAllowed: true)
    )
    let recorder = WhisperEventRecorder()
    let collector = collect(engine.events(), into: recorder)
    engine.primeListeningForTesting(acquireCapture: false)

    engine.appendSamplesForTesting(Self.samples(count: 16_000, value: 0.2), sampleRate: 16_000)
    #expect(await waitForEvent({ await recorder.partialTexts() == ["alpha"] }))

    engine.appendSamplesForTesting(Self.samples(count: 16_000, value: 0.2), sampleRate: 16_000)
    #expect(await waitForEvent({ await recorder.partialTexts().contains("alpha bravo") }))

    engine.appendSamplesForTesting(Self.samples(count: 16_000, value: 0), sampleRate: 16_000)
    #expect(await waitForEvent({ await recorder.segments().count == 1 }))
    let finalized = await recorder.segments().first
    #expect(finalized?.text == "alpha bravo")
    #expect(finalized?.sourceLanguageCode == "en")
    #expect(finalized?.source == .liveATC)
    #expect(abs((finalized?.confidence ?? 0) - 0.64) < 0.0001)

    engine.appendSamplesForTesting(Self.samples(count: 16_000, value: 0.4), sampleRate: 16_000)
    #expect(await waitForEvent({ await recorder.partialTexts().last == "charlie" }))
    #expect(await recorder.partialTexts().last?.contains("alpha") == false)
    collector.cancel()
  }

  @Test func stopMidPartialDoesNotFinalDecodeAndReleasesConduit() async {
    let arbiter = AudioCaptureArbiter()
    let transcriber = FakeWhisperLiveTranscriber { samples, _ in
      [
        WhisperLiveSegment(
          text: "mid partial \(samples.count)",
          startSeconds: 0,
          endSeconds: Double(samples.count) / 16_000,
          avgLogProb: log(0.8)
        )
      ]
    }
    let engine = WhisperKitLiveTranscriptionEngine(
      transcriber: transcriber,
      installedModelFolderURL: { URL(fileURLWithPath: "/tmp/local-whisper", isDirectory: true) },
      localeProvider: { "en-US" },
      arbiter: arbiter,
      audioSession: SpyWhisperAudioSession(),
      authorizer: SpyWhisperAuthorizer(microphoneAllowed: true)
    )
    let recorder = WhisperEventRecorder()
    let collector = collect(engine.events(), into: recorder)
    engine.primeListeningForTesting(acquireCapture: true)

    engine.appendSamplesForTesting(Self.samples(count: 16_000, value: 0.2), sampleRate: 16_000)
    #expect(await waitForEvent({ await recorder.partialTexts().count == 1 }))
    engine.stop()
    try? await Task.sleep(for: .milliseconds(50))

    #expect(await recorder.segments().isEmpty)
    #expect(engine.status == .stopped)
    #expect(arbiter.activeClient == nil)
    collector.cancel()
  }

  @Test func conduitFailureCommitsPendingPartialBeforeFailedStatus() async {
    let transcriber = FakeWhisperLiveTranscriber { _, _ in
      [
        WhisperLiveSegment(
          text: "pending words",
          startSeconds: 0,
          endSeconds: 1,
          avgLogProb: log(0.5)
        )
      ]
    }
    let engine = WhisperKitLiveTranscriptionEngine(
      transcriber: transcriber,
      installedModelFolderURL: { URL(fileURLWithPath: "/tmp/local-whisper", isDirectory: true) },
      localeProvider: { "fr-FR" },
      audioSession: SpyWhisperAudioSession(),
      authorizer: SpyWhisperAuthorizer(microphoneAllowed: true)
    )
    let recorder = WhisperEventRecorder()
    let collector = collect(engine.events(), into: recorder)
    engine.primeListeningForTesting(acquireCapture: true)

    engine.appendSamplesForTesting(Self.samples(count: 16_000, value: 0.2), sampleRate: 16_000)
    #expect(await waitForEvent({ await recorder.partialTexts() == ["pending words"] }))
    engine.simulateCaptureConduitFailureForTesting("capture-failed")

    #expect(await waitForEvent({ await recorder.failedStatuses().count == 1 }))
    let events = await recorder.recordedEvents()
    let committed = await recorder.interimRestartSegments().first
    #expect(committed?.text == "pending words")
    #expect(committed?.confidence == 0)
    #expect(committed?.sourceLanguageCode == "fr")
    #expect(indexOfInterimSegment(in: events) < indexOfFailedStatus(in: events))
    #expect(engine.status == .failed("capture-failed"))
    collector.cancel()
  }

  // why: phase 2 — the WhisperKit engine classifies the segment's OWN window audio through the
  // injected voice-filter gate and stamps the resulting speaker decision onto the final segment
  // event (the VM then suppresses the operator's own read-backs). The gate is consulted only for
  // FINAL decodes, on the exact window samples that produced the segment.
  @Test func finalSegmentCarriesGateSpeakerClassification() async {
    let transcriber = FakeWhisperLiveTranscriber { samples, _ in
      [
        WhisperLiveSegment(
          text: "cleared for takeoff",
          startSeconds: 0,
          endSeconds: Double(samples.count) / 16_000,
          avgLogProb: log(0.7)
        )
      ]
    }
    let gate = StubSpeakerGate(speaker: .pilot(score: 0.95))
    let engine = WhisperKitLiveTranscriptionEngine(
      transcriber: transcriber,
      installedModelFolderURL: { URL(fileURLWithPath: "/tmp/local-whisper", isDirectory: true) },
      localeProvider: { "en-US" },
      bufferGate: gate
    )
    let recorder = WhisperEventRecorder()
    let collector = collect(engine.events(), into: recorder)
    engine.primeListeningForTesting(acquireCapture: false)

    engine.appendSamplesForTesting(Self.samples(count: 16_000, value: 0.2), sampleRate: 16_000)
    engine.appendSamplesForTesting(Self.samples(count: 16_000, value: 0), sampleRate: 16_000)
    #expect(await waitForEvent({ await recorder.segments().count == 1 }))

    let speaker = await recorder.lastSegmentSpeaker()
    guard case .pilot = speaker else {
      Issue.record(
        "final segment must carry the gate's pilot classification, got \(String(describing: speaker))"
      )
      collector.cancel()
      engine.stop()
      return
    }
    #expect(!gate.routedSampleCounts.isEmpty)
    collector.cancel()
    engine.stop()
  }

  @Test func confidenceMappingUsesExpAverageLogProbClampedToUnitRange() {
    #expect(
      abs(WhisperKitLiveTranscriptionEngine.confidence(fromAverageLogProb: log(0.25)) - 0.25)
        < 0.0001)
    #expect(WhisperKitLiveTranscriptionEngine.confidence(fromAverageLogProb: 1.0) == 1)
    #expect(WhisperKitLiveTranscriptionEngine.confidence(fromAverageLogProb: -1_000) == 0)
  }

  // why: HIGH-1 regression. On a real device the live engine ALWAYS resamples (hardware input
  // is 48kHz, never the 16kHz fast path), but that AVAudioConverter path had ZERO coverage — the
  // [Float] appendSamplesForTesting seam feeds already-16kHz samples straight to the window and
  // never touches the converter. These drive the REAL converter with real 48kHz PCM buffers and
  // assert the output is genuinely downsampled (≈ frames*16000/48000, NOT inflated by the prior
  // re-fed-buffer bug) and non-silent (a constant tone survives resample + stereo downmix).
  @Test func resamplesFortyEightKMonoBufferToSixteenKWithoutInflation() throws {
    let engine = Self.makeIdleEngine()
    let buffer = Self.pcmBuffer(sampleRate: 48_000, channels: 1, frames: 48_000, value: 0.2)
    let out = try engine.whisperSamplesForTesting(from: buffer)
    #expect(out.count <= 16_000 + 64, "resample must not inflate (re-fed-buffer duplication)")
    #expect(out.count >= 12_000, "output must be downsampled toward 16kHz, not passed through")
    #expect(out.contains { abs($0) > 0.05 }, "constant tone must survive resampling")
  }

  @Test func resamplesFortyEightKStereoBufferToSixteenKMonoWithoutInflation() throws {
    let engine = Self.makeIdleEngine()
    let buffer = Self.pcmBuffer(sampleRate: 48_000, channels: 2, frames: 48_000, value: 0.2)
    let out = try engine.whisperSamplesForTesting(from: buffer)
    #expect(out.count <= 16_000 + 64, "stereo resample must not inflate")
    #expect(out.count >= 12_000, "stereo input must downsample + downmix toward 16kHz mono")
    #expect(out.contains { abs($0) > 0.05 }, "downmixed constant tone must survive resampling")
  }

  // why: the converter is now session-persistent (one per format, not per buffer). A second
  // buffer of the same format must resample stably through the reused converter — proving the
  // reuse path neither throws nor drifts in length.
  @Test func reusedResampleConverterStaysStableAcrossBuffers() throws {
    let engine = Self.makeIdleEngine()
    let first = try engine.whisperSamplesForTesting(
      from: Self.pcmBuffer(sampleRate: 48_000, channels: 1, frames: 48_000, value: 0.2))
    let second = try engine.whisperSamplesForTesting(
      from: Self.pcmBuffer(sampleRate: 48_000, channels: 1, frames: 48_000, value: 0.2))
    #expect(second.count <= 16_000 + 64)
    #expect(second.count >= 12_000)
    #expect(abs(first.count - second.count) <= 256, "reused converter must not drift in length")
  }

  private static func makeIdleEngine() -> WhisperKitLiveTranscriptionEngine {
    WhisperKitLiveTranscriptionEngine(
      transcriber: FakeWhisperLiveTranscriber { _, _ in [] },
      installedModelFolderURL: { nil },
      localeProvider: { "en-US" },
      authorizer: SpyWhisperAuthorizer(microphoneAllowed: true)
    )
  }

  private static func pcmBuffer(
    sampleRate: Double,
    channels: AVAudioChannelCount,
    frames: AVAudioFrameCount,
    value: Float
  ) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: channels,
      interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(channels) {
      let pointer = buffer.floatChannelData![channel]
      for frame in 0..<Int(frames) { pointer[frame] = value }
    }
    return buffer
  }

  private static func samples(count: Int, value: Float) -> [Float] {
    [Float](repeating: value, count: count)
  }

  private func collect(
    _ events: AsyncStream<LiveTranscriptionEvent>,
    into recorder: WhisperEventRecorder
  ) -> Task<Void, Never> {
    Task { @MainActor in
      for await event in events {
        await recorder.record(event)
      }
    }
  }

  private func waitForEvent(
    _ predicate: @escaping () async -> Bool,
    timeout: Duration = .seconds(30)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await predicate() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await predicate()
  }

  private func indexOfInterimSegment(in events: [LiveTranscriptionEvent]) -> Int {
    events.firstIndex {
      if case .segment(let segment, _) = $0 { return segment.isInterimRestartCommit }
      return false
    } ?? Int.max
  }

  private func indexOfFailedStatus(in events: [LiveTranscriptionEvent]) -> Int {
    events.firstIndex {
      if case .status(.failed) = $0 { return true }
      return false
    } ?? Int.max
  }
}

private actor WhisperEventRecorder {
  private var events: [LiveTranscriptionEvent] = []

  func record(_ event: LiveTranscriptionEvent) {
    events.append(event)
  }

  func recordedEvents() -> [LiveTranscriptionEvent] {
    events
  }

  func partialTexts() -> [String] {
    events.compactMap {
      if case .partial(let text) = $0 { return text }
      return nil
    }
  }

  func segments() -> [TranscriptSegment] {
    events.compactMap {
      if case .segment(let segment, _) = $0 { return segment }
      return nil
    }
  }

  func interimRestartSegments() -> [TranscriptSegment] {
    segments().filter(\.isInterimRestartCommit)
  }

  func lastSegmentSpeaker() -> SpeakerMatchDecision? {
    for event in events.reversed() {
      if case .segment(_, let speaker) = event { return speaker }
    }
    return nil
  }

  func failedStatuses() -> [LiveTranscriptionStatus] {
    events.compactMap {
      if case .status(let status) = $0, case .failed = status { return status }
      return nil
    }
  }
}

@MainActor
private final class StubSpeakerGate: SpeechAudioBufferGate {
  let speaker: SpeakerMatchDecision?
  private(set) var routedSampleCounts: [Int] = []

  init(speaker: SpeakerMatchDecision?) {
    self.speaker = speaker
  }

  func route(samples: [Float], sampleRate: Double) async throws -> GatedAudioRouting {
    routedSampleCounts.append(samples.count)
    return GatedAudioRouting(routing: .transcribe(reason: .nonPilotVoice), speaker: speaker)
  }
}

private actor FakeWhisperLiveTranscriber: WhisperLiveTranscribing {
  struct DecodeRequest: Sendable {
    let sampleCount: Int
    let languageCode: String?
  }

  private let script: @Sendable ([Float], String?) -> [WhisperLiveSegment]
  private var folders: [URL] = []
  private var requests: [DecodeRequest] = []

  init(script: @escaping @Sendable ([Float], String?) -> [WhisperLiveSegment]) {
    self.script = script
  }

  func loadModel(folderURL: URL) async throws {
    folders.append(folderURL)
  }

  func transcribe(samples: [Float], languageCode: String?) async throws -> [WhisperLiveSegment] {
    requests.append(DecodeRequest(sampleCount: samples.count, languageCode: languageCode))
    return script(samples, languageCode)
  }

  func loadedFolders() -> [URL] {
    folders
  }

  func decodeRequests() -> [DecodeRequest] {
    requests
  }
}

@MainActor
private final class SpyWhisperAuthorizer: LiveSpeechAuthorizing {
  private let microphoneAllowed: Bool
  private(set) var speechRequestCount = 0
  private(set) var microphoneRequestCount = 0

  init(microphoneAllowed: Bool) {
    self.microphoneAllowed = microphoneAllowed
  }

  func requestSpeechAuthorization() async -> Bool {
    speechRequestCount += 1
    return true
  }

  func requestMicrophonePermission() async -> Bool {
    microphoneRequestCount += 1
    return microphoneAllowed
  }
}

@MainActor
private final class SpyWhisperAudioSession: LiveAudioSessionManaging {
  private(set) var setActiveCalls: [Bool] = []

  func configureForLiveRecording() throws {}

  func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
    setActiveCalls.append(active)
  }
}
