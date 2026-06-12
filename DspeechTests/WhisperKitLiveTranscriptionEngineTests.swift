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

  @Test func confidenceMappingUsesExpAverageLogProbClampedToUnitRange() {
    #expect(
      abs(WhisperKitLiveTranscriptionEngine.confidence(fromAverageLogProb: log(0.25)) - 0.25)
        < 0.0001)
    #expect(WhisperKitLiveTranscriptionEngine.confidence(fromAverageLogProb: 1.0) == 1)
    #expect(WhisperKitLiveTranscriptionEngine.confidence(fromAverageLogProb: -1_000) == 0)
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
      if case .segment(let segment) = $0 { return segment.isInterimRestartCommit }
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
      if case .segment(let segment) = $0 { return segment }
      return nil
    }
  }

  func interimRestartSegments() -> [TranscriptSegment] {
    segments().filter(\.isInterimRestartCommit)
  }

  func failedStatuses() -> [LiveTranscriptionStatus] {
    events.compactMap {
      if case .status(let status) = $0, case .failed = status { return status }
      return nil
    }
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
