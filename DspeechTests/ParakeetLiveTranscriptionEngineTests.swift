@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import Dspeech

@MainActor
struct ParakeetLiveTranscriptionEngineTests {
  @Test func startWithoutInstalledModelFailsBeforeLoadingTranscriber() async {
    let authorizer = SpyParakeetAuthorizer(microphoneAllowed: true)
    let transcriber = FakeParakeetLiveStreaming()
    let engine = ParakeetLiveTranscriptionEngine(
      transcriber: transcriber,
      installedModelFolderURL: { nil },
      localeProvider: { "en-US" },
      authorizer: authorizer
    )

    await engine.start()

    #expect(engine.status == .failed("parakeet-model-not-installed"))
    #expect(authorizer.microphoneRequestCount == 1)
    #expect(await transcriber.loadedFolders().isEmpty)
  }

  @Test func startWithNonEnglishLocaleFailsLocaleGateBeforeModelLoad() async {
    let transcriber = FakeParakeetLiveStreaming()
    let engine = ParakeetLiveTranscriptionEngine(
      transcriber: transcriber,
      installedModelFolderURL: { URL(fileURLWithPath: "/tmp/parakeet", isDirectory: true) },
      localeProvider: { "fr-FR" },
      authorizer: SpyParakeetAuthorizer(microphoneAllowed: true)
    )

    await engine.start()

    #expect(engine.status == .failed("parakeet-requires-english-locale"))
    #expect(await transcriber.loadedFolders().isEmpty)
  }

  // why: the locale gate rejects EVERY concrete non-en BCP-47 family, never just fr-FR.
  @Test func startRejectsEveryNonEnglishLocale() async {
    for locale in ["fr-FR", "de-DE", "es-ES", "ja-JP", "ru-RU", "zh-Hans", "pt-BR"] {
      let engine = ParakeetLiveTranscriptionEngine(
        transcriber: FakeParakeetLiveStreaming(),
        installedModelFolderURL: { URL(fileURLWithPath: "/tmp/parakeet", isDirectory: true) },
        localeProvider: { locale },
        authorizer: SpyParakeetAuthorizer(microphoneAllowed: true)
      )
      await engine.start()
      #expect(
        engine.status == .failed("parakeet-requires-english-locale"),
        "locale \(locale) must be rejected by the English-only gate")
    }
  }

  @Test func startWithDeniedMicrophoneFails() async {
    let engine = ParakeetLiveTranscriptionEngine(
      transcriber: FakeParakeetLiveStreaming(),
      installedModelFolderURL: { URL(fileURLWithPath: "/tmp/parakeet", isDirectory: true) },
      localeProvider: { "en-US" },
      authorizer: SpyParakeetAuthorizer(microphoneAllowed: false)
    )

    await engine.start()

    #expect(engine.status == .failed("microphone-permission-denied"))
  }

  @Test func partialCallbackEmitsPartialEvent() async {
    let transcriber = FakeParakeetLiveStreaming()
    let engine = ParakeetLiveTranscriptionEngine(
      transcriber: transcriber,
      installedModelFolderURL: { URL(fileURLWithPath: "/tmp/parakeet", isDirectory: true) },
      localeProvider: { "en-US" },
      authorizer: SpyParakeetAuthorizer(microphoneAllowed: true)
    )
    let recorder = ParakeetEventRecorder()
    let collector = collect(engine.events(), into: recorder)
    await engine.primeListeningForTesting(acquireCapture: false)

    await transcriber.firePartial("tower one two three")
    #expect(await waitForEvent({ await recorder.partialTexts() == ["tower one two three"] }))

    collector.cancel()
    engine.stop()
  }

  @Test func endOfUtteranceCallbackEmitsFinalSegment() async {
    let transcriber = FakeParakeetLiveStreaming()
    let engine = ParakeetLiveTranscriptionEngine(
      transcriber: transcriber,
      installedModelFolderURL: { URL(fileURLWithPath: "/tmp/parakeet", isDirectory: true) },
      localeProvider: { "en-US" },
      authorizer: SpyParakeetAuthorizer(microphoneAllowed: true)
    )
    let recorder = ParakeetEventRecorder()
    let collector = collect(engine.events(), into: recorder)
    await engine.primeListeningForTesting(acquireCapture: false)

    await transcriber.fireEndOfUtterance("november one two three cleared to land")
    #expect(await waitForEvent({ await recorder.segments().count == 1 }))

    let segment = await recorder.segments().first
    #expect(segment?.text == "november one two three cleared to land")
    #expect(segment?.sourceLanguageCode == "en")
    #expect(segment?.source == .liveATC)
    // why: streaming EOU yields no confidence — honest "unknown" (0), flags requiresVerification.
    #expect(segment?.confidence == 0)
    #expect(segment?.requiresVerification == true)
    #expect(await recorder.lastSegmentSpeaker() == nil)

    collector.cancel()
    engine.stop()
  }

  @Test func emptyEndOfUtteranceDoesNotEmitSegment() async {
    let transcriber = FakeParakeetLiveStreaming()
    let engine = ParakeetLiveTranscriptionEngine(
      transcriber: transcriber,
      installedModelFolderURL: { URL(fileURLWithPath: "/tmp/parakeet", isDirectory: true) },
      localeProvider: { "en-US" },
      authorizer: SpyParakeetAuthorizer(microphoneAllowed: true)
    )
    let recorder = ParakeetEventRecorder()
    let collector = collect(engine.events(), into: recorder)
    await engine.primeListeningForTesting(acquireCapture: false)

    await transcriber.firePartial("alpha")
    #expect(await waitForEvent({ await recorder.partialTexts() == ["alpha"] }))
    await transcriber.fireEndOfUtterance("   ")
    // give the MainActor hop a chance to run, then assert no segment was produced
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await recorder.segments().isEmpty)

    collector.cancel()
    engine.stop()
  }

  @Test func stopTransitionsToStoppedAndCleansUpTranscriber() async {
    let arbiter = AudioCaptureArbiter()
    let transcriber = FakeParakeetLiveStreaming()
    let engine = ParakeetLiveTranscriptionEngine(
      transcriber: transcriber,
      installedModelFolderURL: { URL(fileURLWithPath: "/tmp/parakeet", isDirectory: true) },
      localeProvider: { "en-US" },
      arbiter: arbiter,
      audioSession: SpyParakeetAudioSession(),
      authorizer: SpyParakeetAuthorizer(microphoneAllowed: true)
    )
    let recorder = ParakeetEventRecorder()
    let collector = collect(engine.events(), into: recorder)
    await engine.primeListeningForTesting(acquireCapture: true)

    engine.stop()

    #expect(engine.status == .stopped)
    #expect(arbiter.activeClient == nil)
    #expect(await waitForEvent({ await transcriber.cleanupCount() == 1 }))

    collector.cancel()
  }

  // why: after stop the lifecycle generation is bumped, so a late EOU callback from the
  // still-installed FluidAudio closure must be dropped — never finalize a segment post-stop.
  @Test func endOfUtteranceAfterStopIsIgnored() async {
    let transcriber = FakeParakeetLiveStreaming()
    let engine = ParakeetLiveTranscriptionEngine(
      transcriber: transcriber,
      installedModelFolderURL: { URL(fileURLWithPath: "/tmp/parakeet", isDirectory: true) },
      localeProvider: { "en-US" },
      authorizer: SpyParakeetAuthorizer(microphoneAllowed: true)
    )
    let recorder = ParakeetEventRecorder()
    let collector = collect(engine.events(), into: recorder)
    await engine.primeListeningForTesting(acquireCapture: false)
    engine.stop()

    await transcriber.fireEndOfUtterance("stale clearance")
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await recorder.segments().isEmpty)

    collector.cancel()
  }

  private func collect(
    _ events: AsyncStream<LiveTranscriptionEvent>,
    into recorder: ParakeetEventRecorder
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
}

private actor ParakeetEventRecorder {
  private var events: [LiveTranscriptionEvent] = []

  func record(_ event: LiveTranscriptionEvent) {
    events.append(event)
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

  func lastSegmentSpeaker() -> SpeakerMatchDecision? {
    for event in events.reversed() {
      if case .segment(_, let speaker) = event { return speaker }
    }
    return nil
  }
}

private actor FakeParakeetLiveStreaming: ParakeetLiveStreaming {
  private var folders: [URL] = []
  private var partialCallback: (@Sendable (String) -> Void)?
  private var eouCallback: (@Sendable (String) -> Void)?
  private var appendedSampleCounts: [Int] = []
  private var processCount = 0
  private var cleanupCalls = 0

  func loadModels(from folderURL: URL) async throws {
    folders.append(folderURL)
  }

  func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async {
    partialCallback = callback
  }

  func setEouCallback(_ callback: @escaping @Sendable (String) -> Void) async {
    eouCallback = callback
  }

  func appendSamples(_ samples: [Float], sampleRate: Double) async throws {
    appendedSampleCounts.append(samples.count)
  }

  func processBufferedAudio() async throws {
    processCount += 1
  }

  func reset() async throws {}

  func cleanup() async {
    cleanupCalls += 1
  }

  func firePartial(_ text: String) {
    partialCallback?(text)
  }

  func fireEndOfUtterance(_ text: String) {
    eouCallback?(text)
  }

  func loadedFolders() -> [URL] { folders }
  func cleanupCount() -> Int { cleanupCalls }
}

@MainActor
private final class SpyParakeetAuthorizer: LiveSpeechAuthorizing {
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
private final class SpyParakeetAudioSession: LiveAudioSessionManaging {
  private(set) var setActiveCalls: [Bool] = []

  func configureForLiveRecording() throws {}

  func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
    setActiveCalls.append(active)
  }
}
