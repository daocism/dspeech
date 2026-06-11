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

  @Test func realRecognitionFaultSurfacesAsFailure() {
    let failure = ASRFailure(domain: "kAFAssistantErrorDomain", code: 203, message: "Retry")
    let decision = AppleSpeechLiveTranscriptionEngine.terminationDecision(
      isListening: true, hasRecognizer: true, failure: failure)
    #expect(decision == .fail("asr-error: kAFAssistantErrorDomain#203 Retry"))
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
