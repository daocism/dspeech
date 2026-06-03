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
