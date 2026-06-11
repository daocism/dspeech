@preconcurrency import AVFoundation
import Testing

@testable import Dspeech

@MainActor
struct AppleSpeechLiveTranscriptionEngineLifecycleTests {
  @Test func duplicateStartWhileSpeechAuthorizationPendingUsesOneRequest() async {
    let authorizer = SuspendedLiveSpeechAuthorizer()
    let engine = AppleSpeechLiveTranscriptionEngine(
      requireOnDeviceModel: false,
      authorizer: authorizer
    )
    let firstStart = Task { @MainActor in await engine.start() }

    #expect(await wait(for: { authorizer.speechRequestCount == 1 }))

    let duplicateStart = Task { @MainActor in await engine.start() }
    await duplicateStart.value

    #expect(authorizer.speechRequestCount == 1)

    authorizer.resolveSpeech(false)
    await firstStart.value
    #expect(engine.status == .failed("speech-permission-denied"))
  }

  @Test func stopDuringSpeechAuthorizationKeepsStoppedAfterLateDenial() async {
    let authorizer = SuspendedLiveSpeechAuthorizer()
    let engine = AppleSpeechLiveTranscriptionEngine(
      requireOnDeviceModel: false,
      authorizer: authorizer
    )
    let startTask = Task { @MainActor in await engine.start() }

    #expect(await wait(for: { authorizer.speechRequestCount == 1 }))

    engine.stop()
    #expect(engine.status == .stopped)

    authorizer.resolveSpeech(false)
    await startTask.value
    #expect(engine.status == .stopped)
    #expect(authorizer.microphoneRequestCount == 0)
  }

  @Test func stopDuringMicrophoneAuthorizationKeepsStoppedAfterLateGrant() async {
    let authorizer = SuspendedLiveSpeechAuthorizer()
    let engine = AppleSpeechLiveTranscriptionEngine(
      requireOnDeviceModel: false,
      authorizer: authorizer
    )
    let startTask = Task { @MainActor in await engine.start() }

    #expect(await wait(for: { authorizer.speechRequestCount == 1 }))
    authorizer.resolveSpeech(true)
    #expect(await wait(for: { authorizer.microphoneRequestCount == 1 }))

    engine.stop()
    #expect(engine.status == .stopped)

    authorizer.resolveMicrophone(true)
    await startTask.value
    #expect(engine.status == .stopped)
  }

  @Test func startFailsVisiblyWhenRecognitionLocaleIsUnavailable() async {
    let engine = AppleSpeechLiveTranscriptionEngine(
      localeProvider: { nil },
      requireOnDeviceModel: false,
      authorizer: ImmediateLiveSpeechAuthorizer()
    )

    await engine.start()

    #expect(engine.status == .failed("recognition-locale-unavailable"))
  }

  // why: the restart-vs-surface decision is the F1 silent-failure fix and was previously
  // shipped with zero behavioral coverage. These pin the exact branches: a benign no-speech
  // timeout (1110) keeps listening; a real fault surfaces as a visible .failed; a normal final
  // (no failure) restarts; and a callback that arrives when not listening / without a recognizer
  // is ignored so a superseded task can't flip a torn-down session.
  @Test func benignNoSpeechTimeoutRestarts() {
    let failure = ASRFailure(domain: "kAFAssistantErrorDomain", code: 1110, message: "No speech")
    #expect(
      AppleSpeechLiveTranscriptionEngine.terminationDecision(
        isListening: true, hasRecognizer: true, failure: failure) == .restart)
  }

  @Test func retryAssetHiccupRestarts() {
    let failure = ASRFailure(domain: "kAFAssistantErrorDomain", code: 203, message: "Retry")
    #expect(
      AppleSpeechLiveTranscriptionEngine.terminationDecision(
        isListening: true, hasRecognizer: true, failure: failure) == .restart)
  }

  @Test func requestTimedOutTerminationRestarts() {
    let failure = ASRFailure(
      domain: "SFSpeechErrorDomain",
      code: 1,
      message: "Recognition request timed out.")
    #expect(
      AppleSpeechLiveTranscriptionEngine.terminationDecision(
        isListening: true, hasRecognizer: true, failure: failure) == .restart)
  }

  @Test func durationLimitTerminationRestarts() {
    let failure = ASRFailure(
      domain: "SFSpeechErrorDomain",
      code: 1,
      message: "Recognition duration limit was reached.")
    #expect(
      AppleSpeechLiveTranscriptionEngine.terminationDecision(
        isListening: true, hasRecognizer: true, failure: failure) == .restart)
  }

  @Test func realRecognitionFaultSurfacesAsFailure() {
    let failure = ASRFailure(domain: "kAFAssistantErrorDomain", code: 203, message: "Asset failed")
    let decision = AppleSpeechLiveTranscriptionEngine.terminationDecision(
      isListening: true, hasRecognizer: true, failure: failure)
    #expect(decision == .fail("asr-error: kAFAssistantErrorDomain#203 Asset failed"))
  }

  @Test func normalFinalWithNoFailureRestarts() {
    #expect(
      AppleSpeechLiveTranscriptionEngine.terminationDecision(
        isListening: true, hasRecognizer: true, failure: nil) == .restart)
  }

  @Test func terminationIgnoredWhenNotListening() {
    let failure = ASRFailure(domain: "kAFAssistantErrorDomain", code: 203, message: "Retry")
    #expect(
      AppleSpeechLiveTranscriptionEngine.terminationDecision(
        isListening: false, hasRecognizer: true, failure: failure) == .ignore)
  }

  @Test func terminationIgnoredWhenRecognizerGone() {
    #expect(
      AppleSpeechLiveTranscriptionEngine.terminationDecision(
        isListening: true, hasRecognizer: false, failure: nil) == .ignore)
  }

  @Test func restartDecisionFailsWhenListeningEngineIsNotRunning() {
    #expect(
      AppleSpeechLiveTranscriptionEngine.restartDecision(
        isListening: true, isAudioEngineRunning: false)
        == .fail("engine-died-before-restart"))
  }

  @Test func restartLoopGuardFailsAfterTooManyRestartsWithoutResults() {
    let clock = ContinuousClock()
    let start = clock.now
    var guardState = ASRRestartLoopGuard(maxRestartCount: 5, window: .seconds(10))

    for offset in 0..<5 {
      #expect(guardState.recordRestart(now: start.advanced(by: .seconds(offset))) == .allow)
    }

    #expect(
      guardState.recordRestart(now: start.advanced(by: .seconds(5)))
        == .fail("asr-restart-loop"))
  }

  @Test func restartLoopGuardResetsAfterAnyRecognitionResult() {
    let clock = ContinuousClock()
    let start = clock.now
    var guardState = ASRRestartLoopGuard(maxRestartCount: 5, window: .seconds(10))

    for offset in 0..<5 {
      #expect(guardState.recordRestart(now: start.advanced(by: .seconds(offset))) == .allow)
    }
    guardState.recordResult()

    #expect(guardState.recordRestart(now: start.advanced(by: .seconds(6))) == .allow)
  }

  @Test func restartLoopGuardForgetsRestartsOutsideWindow() {
    let clock = ContinuousClock()
    let start = clock.now
    var guardState = ASRRestartLoopGuard(maxRestartCount: 5, window: .seconds(10))

    for offset in 0..<5 {
      #expect(guardState.recordRestart(now: start.advanced(by: .seconds(offset))) == .allow)
    }

    #expect(guardState.recordRestart(now: start.advanced(by: .seconds(11))) == .allow)
  }

  @Test func startupGateRetriesTransientUnsupportedRead() {
    let first = RecognizerCapabilityRead(isAvailable: true, supportsOnDeviceRecognition: false)
    let second = RecognizerCapabilityRead(isAvailable: true, supportsOnDeviceRecognition: true)

    #expect(
      AppleSpeechLiveTranscriptionEngine.startupGateDecision(
        firstRead: first,
        secondRead: second,
        requireOnDeviceModel: true,
        skipPermissionRequests: false
      ) == .ready)
  }

  @Test func startupGateFailsAfterRepeatedUnsupportedRead() {
    let first = RecognizerCapabilityRead(isAvailable: true, supportsOnDeviceRecognition: false)
    let second = RecognizerCapabilityRead(isAvailable: true, supportsOnDeviceRecognition: false)

    #expect(
      AppleSpeechLiveTranscriptionEngine.startupGateDecision(
        firstRead: first,
        secondRead: second,
        requireOnDeviceModel: true,
        skipPermissionRequests: false
      ) == .fail("on-device-model-missing"))
  }

  @Test func sourceLanguageCodeKeepsThreeLetterLanguageCodes() {
    #expect(AppleSpeechLiveTranscriptionEngine.sourceLanguageCode(for: "yue-Hant-HK") == "yue")
  }

  @Test func replayTailKeepsOnlyBoundedRecentBuffers() {
    var tail = AudioReplayTail<Int>(maxDurationSeconds: 1, maxBufferCount: 4)

    tail.append(1, sampleCount: 16_000, sampleRate: 16_000)
    tail.append(2, sampleCount: 8_000, sampleRate: 16_000)
    tail.append(3, sampleCount: 8_000, sampleRate: 16_000)
    tail.append(4, sampleCount: 8_000, sampleRate: 16_000)

    #expect(tail.buffers == [3, 4])
  }

  @Test func replayTailDropsOldestBuffersWhenCountBoundIsHit() {
    var tail = AudioReplayTail<Int>(maxDurationSeconds: 10, maxBufferCount: 2)

    tail.append(1, sampleCount: 1, sampleRate: 16_000)
    tail.append(2, sampleCount: 1, sampleRate: 16_000)
    tail.append(3, sampleCount: 1, sampleRate: 16_000)

    #expect(tail.buffers == [2, 3])
  }

  @Test func eventsMulticastToMultipleSubscribers() async {
    let engine = AppleSpeechLiveTranscriptionEngine(
      requireOnDeviceModel: false,
      skipPermissionRequests: true,
      audioSession: SpyLiveAudioSession()
    )
    let first = EventCursor(engine.events())
    let second = EventCursor(engine.events())

    #expect(await first.nextStatus() == .idle)
    #expect(await second.nextStatus() == .idle)

    engine.primeListeningForTesting(acquireCapture: false)

    #expect(await first.nextStatus() == .listening)
    #expect(await second.nextStatus() == .listening)
  }

  @Test func recognizerUnavailableWhileListeningFailsVisibly() {
    let engine = AppleSpeechLiveTranscriptionEngine(
      requireOnDeviceModel: false,
      skipPermissionRequests: true,
      audioSession: SpyLiveAudioSession()
    )
    engine.primeListeningForTesting(acquireCapture: true)

    engine.simulateRecognizerAvailabilityChangeForTesting(false)

    #expect(engine.status == .failed("recognizer-became-unavailable"))
  }

  @Test func orderedCallbackConduitDropsStalePartialAfterFinalRestart() async {
    let engine = AppleSpeechLiveTranscriptionEngine(
      requireOnDeviceModel: false,
      skipPermissionRequests: true,
      audioSession: SpyLiveAudioSession()
    )
    let recorder = EventRecorder()
    // why: subscribe synchronously BEFORE any emit — the multicast stream only buffers
    // for already-registered continuations, and on a starved CI runner the collector
    // Task can otherwise start after the first yield (observed hosted-runner-only flake).
    let events = engine.events()
    let collector = Task { @MainActor in
      for await event in events {
        await recorder.record(event)
      }
    }
    engine.installRecognitionCallbackConduitForTesting(generation: 7)
    let final = TranscriptSegment(
      text: "November one two three alpha bravo",
      confidence: 0.9,
      sourceLanguageCode: "en",
      source: .liveATC
    )

    engine.emitRecognitionCallbackForTesting(
      generation: 7,
      event: .segment(final),
      isFinal: true,
      hasResult: true
    )
    #expect(await waitForEvent({ await recorder.segmentTexts().contains(final.text) }))

    engine.advanceTaskGenerationForTesting()
    engine.emitRecognitionCallbackForTesting(
      generation: 7,
      event: .partial("stale partial"),
      isFinal: false,
      hasResult: true
    )
    for _ in 0..<50 { await Task.yield() }

    #expect(!(await recorder.partialTexts().contains("stale partial")))
    collector.cancel()
  }

  @Test func startFailsWhenCaptureSessionIsBusy() async {
    let arbiter = AudioCaptureArbiter()
    #expect(arbiter.acquire(.callsignDictation))
    let engine = AppleSpeechLiveTranscriptionEngine(
      requireOnDeviceModel: false,
      skipPermissionRequests: true,
      arbiter: arbiter,
      audioSession: SpyLiveAudioSession()
    )

    await engine.start()

    #expect(engine.status == .failed("capture-session-busy"))
    #expect(arbiter.activeClient == .callsignDictation)
  }

  @Test func stopReleasesLiveCaptureAndDeactivatesWhenHolder() {
    let arbiter = AudioCaptureArbiter()
    let audioSession = SpyLiveAudioSession()
    let engine = AppleSpeechLiveTranscriptionEngine(
      requireOnDeviceModel: false,
      skipPermissionRequests: true,
      arbiter: arbiter,
      audioSession: audioSession
    )
    engine.primeListeningForTesting(acquireCapture: true)
    #expect(arbiter.activeClient == .liveTranscription)

    engine.stop()

    #expect(arbiter.activeClient == nil)
    #expect(audioSession.setActiveCalls == [.inactive(options: .notifyOthersOnDeactivation)])
  }

  @Test func stopSkipsDeactivationWhenLiveCaptureIsNotHolder() {
    let arbiter = AudioCaptureArbiter()
    let audioSession = SpyLiveAudioSession()
    let engine = AppleSpeechLiveTranscriptionEngine(
      requireOnDeviceModel: false,
      skipPermissionRequests: true,
      arbiter: arbiter,
      audioSession: audioSession
    )
    engine.primeListeningForTesting(acquireCapture: false)

    engine.stop()

    #expect(arbiter.activeClient == nil)
    #expect(audioSession.setActiveCalls.isEmpty)
  }

  @discardableResult
  private func wait(
    for predicate: @MainActor () -> Bool,
    timeout: Duration = .seconds(5)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return predicate()
  }

  // why: a mutating AsyncStream iterator cannot live on an actor under Swift 6 region
  // isolation; a nonisolated non-Sendable cursor keeps iteration in its own region and is
  // legally awaited from the MainActor tests.
  private final class EventCursor {
    private var iterator: AsyncStream<LiveTranscriptionEvent>.Iterator

    init(_ stream: AsyncStream<LiveTranscriptionEvent>) {
      iterator = stream.makeAsyncIterator()
    }

    func nextStatus() async -> LiveTranscriptionStatus? {
      guard let event = await iterator.next() else { return nil }
      if case .status(let status) = event { return status }
      return nil
    }
  }

  private func waitForEvent(
    _ predicate: @escaping () async -> Bool,
    timeout: Duration = .seconds(5)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await predicate() { return true }
      await Task.yield()
    }
    return await predicate()
  }
}

private actor EventRecorder {
  private var events: [LiveTranscriptionEvent] = []

  func record(_ event: LiveTranscriptionEvent) {
    events.append(event)
  }

  func segmentTexts() -> [String] {
    events.compactMap {
      if case .segment(let segment) = $0 { return segment.text }
      return nil
    }
  }

  func partialTexts() -> [String] {
    events.compactMap {
      if case .partial(let text) = $0 { return text }
      return nil
    }
  }
}

@MainActor
private struct ImmediateLiveSpeechAuthorizer: LiveSpeechAuthorizing {
  func requestSpeechAuthorization() async -> Bool { true }
  func requestMicrophonePermission() async -> Bool { true }
}

@MainActor
private final class SpyLiveAudioSession: LiveAudioSessionManaging {
  enum SetActiveCall: Equatable {
    case active(options: AVAudioSession.SetActiveOptions)
    case inactive(options: AVAudioSession.SetActiveOptions)
  }

  private(set) var configuredForLiveRecording = false
  private(set) var setActiveCalls: [SetActiveCall] = []

  func configureForLiveRecording() throws {
    configuredForLiveRecording = true
  }

  func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
    setActiveCalls.append(active ? .active(options: options) : .inactive(options: options))
  }
}

@MainActor
private final class SuspendedLiveSpeechAuthorizer: LiveSpeechAuthorizing {
  private(set) var speechRequestCount = 0
  private(set) var microphoneRequestCount = 0
  private var speechContinuation: CheckedContinuation<Bool, Never>?
  private var microphoneContinuation: CheckedContinuation<Bool, Never>?

  func requestSpeechAuthorization() async -> Bool {
    speechRequestCount += 1
    return await withCheckedContinuation { continuation in
      speechContinuation = continuation
    }
  }

  func requestMicrophonePermission() async -> Bool {
    microphoneRequestCount += 1
    return await withCheckedContinuation { continuation in
      microphoneContinuation = continuation
    }
  }

  func resolveSpeech(_ isAuthorized: Bool) {
    let continuation = speechContinuation
    speechContinuation = nil
    continuation?.resume(returning: isAuthorized)
  }

  func resolveMicrophone(_ isAllowed: Bool) {
    let continuation = microphoneContinuation
    microphoneContinuation = nil
    continuation?.resume(returning: isAllowed)
  }
}
