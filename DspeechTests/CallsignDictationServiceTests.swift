@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import Dspeech

@MainActor
struct CallsignDictationServiceTests {
  @Test func speechAuthorizationDeniedSurfacesUnavailable() async {
    let authorization = FakeAuthorization(speechAllowed: false)
    let recognizer = FakeCallsignRecognizer()
    let service = makeService(authorization: authorization, recognizer: recognizer)

    await service.start()

    #expect(
      service.status
        == .unavailable("No speech recognition access. Allow it in Settings."))
    #expect(authorization.speechCallCount == 1)
    #expect(authorization.micCallCount == 0)
    #expect(recognizer.startCallCount == 0)
  }

  @Test func busyCaptureSurfacesUnavailableWithoutStartingRecognitionOrCapture() async {
    let arbiter = AudioCaptureArbiter()
    #expect(arbiter.acquire(.liveTranscription))
    let authorization = FakeAuthorization()
    let recognizer = FakeCallsignRecognizer()
    let audioCapture = FakeCallsignAudioCapture()
    let service = makeService(
      authorization: authorization,
      recognizer: recognizer,
      audioCapture: audioCapture,
      arbiter: arbiter
    )

    await service.start()

    #expect(
      service.status
        == .unavailable(
          "Audio capture is already in use. Stop transcription before using voice entry."))
    #expect(authorization.speechCallCount == 0)
    #expect(authorization.micCallCount == 0)
    #expect(recognizer.startCallCount == 0)
    #expect(audioCapture.startCallCount == 0)
    #expect(arbiter.activeClient == .liveTranscription)
  }

  @Test func microphonePermissionDeniedSurfacesUnavailable() async {
    let authorization = FakeAuthorization(microphoneAllowed: false)
    let recognizer = FakeCallsignRecognizer()
    let service = makeService(authorization: authorization, recognizer: recognizer)

    await service.start()

    #expect(service.status == .unavailable("No microphone access. Allow it in Settings."))
    #expect(authorization.speechCallCount == 1)
    #expect(authorization.micCallCount == 1)
    #expect(recognizer.startCallCount == 0)
  }

  @Test func nilRecognizerSurfacesUnavailable() async {
    let service = makeService(recognizer: nil)

    await service.start()

    #expect(service.status == .unavailable("Speech recognition isn't available on this device."))
  }

  @Test func unavailableRecognizerSurfacesUnavailable() async {
    let recognizer = FakeCallsignRecognizer(isAvailable: false)
    let service = makeService(recognizer: recognizer)

    await service.start()

    #expect(service.status == .unavailable("Speech recognition isn't available on this device."))
    #expect(recognizer.startCallCount == 0)
  }

  @Test func missingOnDeviceModelSurfacesUnavailable() async {
    let recognizer = FakeCallsignRecognizer(supportsOnDeviceRecognition: false)
    let service = makeService(localeIdentifier: "fr-FR", recognizer: recognizer)

    await service.start()

    #expect(
      service.status
        == .unavailable(
          "Offline recognition for fr-FR is not installed. Voice entry of the callsign requires a local model."
        )
    )
    #expect(recognizer.startCallCount == 0)
  }

  @Test func captureStartFailureCleansRecognitionSession() async {
    let recognizer = FakeCallsignRecognizer()
    let audioCapture = FakeCallsignAudioCapture(startError: ScriptedError.captureStart)
    let service = makeService(recognizer: recognizer, audioCapture: audioCapture)

    await service.start()

    guard case .unavailable(let reason) = service.status else {
      Issue.record("expected unavailable status")
      return
    }
    #expect(reason.contains("start recording"))
    #expect(recognizer.startCallCount == 1)
    #expect(recognizer.endAudioCallCount == 1)
    #expect(recognizer.task.cancelCallCount == 1)
  }

  @Test func startBeginsRecognitionBeforeCaptureAndAppendsCaptureStartBuffer() async {
    var events: [String] = []
    let recognizer = FakeCallsignRecognizer(onStart: { events.append("recognition-start") })
    recognizer.onAppend = { events.append("append") }
    let audioCapture = FakeCallsignAudioCapture(
      buffersOnStart: [Self.makeBuffer()],
      onStart: { events.append("capture-start") }
    )
    let service = makeService(recognizer: recognizer, audioCapture: audioCapture)

    await service.start()
    #expect(await Self.wait(for: { recognizer.appendedBuffers.count == 1 }))

    #expect(service.status == .listening)
    #expect(events.prefix(2) == ["recognition-start", "capture-start"])
    #expect(events.contains("append"))
  }

  @Test func startUsesInjectedRecognitionLocaleProvider() async {
    let recognizer = FakeCallsignRecognizer()
    var requestedLocales: [String] = []
    let service = CallsignDictationService(
      localeProvider: { "fr-FR" },
      authorization: FakeAuthorization(),
      recognizerFactory: { localeIdentifier in
        requestedLocales.append(localeIdentifier)
        return recognizer
      },
      audioCapture: FakeCallsignAudioCapture(),
      arbiter: AudioCaptureArbiter()
    )

    await service.start()

    #expect(requestedLocales == ["fr-FR"])
    #expect(service.status == .listening)
  }

  @Test func startSurfacesUnavailableWhenRecognitionLocaleProviderReturnsNil() async {
    let recognizer = FakeCallsignRecognizer()
    let service = CallsignDictationService(
      localeProvider: { nil },
      authorization: FakeAuthorization(),
      recognizerFactory: { _ in recognizer },
      audioCapture: FakeCallsignAudioCapture(),
      arbiter: AudioCaptureArbiter()
    )

    await service.start()

    #expect(service.status == .unavailable("No recognition language available."))
    #expect(recognizer.startCallCount == 0)
  }

  @Test func recognitionRequestSeedsAviationContextualStrings() async {
    let recognizer = FakeCallsignRecognizer()
    let service = makeService(recognizer: recognizer)

    await service.start()

    #expect(recognizer.contextualStrings.contains("Alpha"))
    #expect(recognizer.contextualStrings.contains("Niner"))
  }

  @Test func partialRecognitionUpdateChangesLiveTranscript() async {
    let recognizer = FakeCallsignRecognizer()
    let service = makeService(recognizer: recognizer)
    await service.start()

    recognizer.push(
      CallsignRecognitionUpdate(text: "november one", isFinished: false, hardError: nil))
    #expect(await Self.wait(for: { service.liveTranscript == "november one" }))

    #expect(service.status == .listening)
  }

  @Test func benignFinalRecognitionReturnsToIdle() async {
    let recognizer = FakeCallsignRecognizer()
    let audioCapture = FakeCallsignAudioCapture()
    let service = makeService(recognizer: recognizer, audioCapture: audioCapture)
    await service.start()

    recognizer.push(
      CallsignRecognitionUpdate(text: "november one", isFinished: true, hardError: nil))
    #expect(await Self.wait(for: { service.status == .idle }))

    #expect(service.liveTranscript == "november one")
    #expect(audioCapture.stopCallCount == 1)
    #expect(recognizer.endAudioCallCount == 1)
    #expect(recognizer.task.cancelCallCount == 1)
  }

  @Test func hardRecognitionErrorSurfacesEvenWhenDeliveredDuringStartup() async {
    let recognizer = FakeCallsignRecognizer(
      updatesOnStart: [
        CallsignRecognitionUpdate(
          text: nil,
          isFinished: true,
          hardError: "SpeechDomain#7 scripted failure"
        )
      ]
    )
    let service = makeService(recognizer: recognizer)

    await service.start()
    #expect(
      await Self.wait(for: {
        service.status
          == .unavailable("Couldn’t recognize speech: SpeechDomain#7 scripted failure")
      })
    )
  }

  @Test func stopCleansCaptureRecognitionAndTask() async {
    let recognizer = FakeCallsignRecognizer()
    let audioCapture = FakeCallsignAudioCapture()
    let service = makeService(recognizer: recognizer, audioCapture: audioCapture)
    await service.start()

    service.stop()

    #expect(service.status == .idle)
    #expect(audioCapture.stopCallCount == 1)
    #expect(recognizer.endAudioCallCount == 1)
    #expect(recognizer.task.cancelCallCount == 1)
  }

  @Test func stopReleasesCaptureArbiter() async {
    let arbiter = AudioCaptureArbiter()
    let service = makeService(arbiter: arbiter)

    await service.start()
    #expect(arbiter.activeClient == .callsignDictation)

    service.stop()

    #expect(arbiter.activeClient == nil)
  }

  @Test func stopWhenNoLongerArbiterHolderDoesNotDeactivateSession() async {
    let arbiter = AudioCaptureArbiter()
    let audioCapture = FakeCallsignAudioCapture()
    let service = makeService(audioCapture: audioCapture, arbiter: arbiter)

    await service.start()
    #expect(arbiter.release(.callsignDictation))

    service.stop()

    #expect(audioCapture.deactivationRequests == [false])
    #expect(arbiter.activeClient == nil)
  }

  @Test func duplicateStartWhileAuthorizationPendingUsesOneSession() async {
    let authorization = FakeAuthorization(suspendSpeech: true)
    let recognizer = FakeCallsignRecognizer()
    let service = makeService(authorization: authorization, recognizer: recognizer)

    let firstStart = Task { await service.start() }
    #expect(
      await Self.wait(for: { authorization.speechCallCount == 1 && service.status == .starting }))

    await service.start()
    #expect(authorization.speechCallCount == 1)

    authorization.resumeSpeech(true)
    await firstStart.value

    #expect(service.status == .listening)
    #expect(authorization.micCallCount == 1)
    #expect(recognizer.startCallCount == 1)
  }

  @Test func stopDuringAuthorizationPreventsLateStartup() async {
    let authorization = FakeAuthorization(suspendSpeech: true)
    let recognizer = FakeCallsignRecognizer()
    let service = makeService(authorization: authorization, recognizer: recognizer)

    let startTask = Task { await service.start() }
    #expect(
      await Self.wait(for: { authorization.speechCallCount == 1 && service.status == .starting }))

    service.stop()
    authorization.resumeSpeech(true)
    await startTask.value

    #expect(service.status == .idle)
    #expect(authorization.micCallCount == 0)
    #expect(recognizer.startCallCount == 0)
  }

  @Test func lateBufferAfterStopIsIgnored() async {
    let recognizer = FakeCallsignRecognizer()
    let audioCapture = FakeCallsignAudioCapture()
    let service = makeService(recognizer: recognizer, audioCapture: audioCapture)
    await service.start()
    service.stop()

    audioCapture.emit(Self.makeBuffer())
    for _ in 0..<20 { await Task.yield() }

    #expect(recognizer.appendedBuffers.isEmpty)
  }

  @Test func staleRecognitionUpdateAfterStopIsIgnored() async {
    let recognizer = FakeCallsignRecognizer()
    let service = makeService(recognizer: recognizer)
    await service.start()
    service.stop()

    recognizer.push(
      CallsignRecognitionUpdate(
        text: nil,
        isFinished: true,
        hardError: "SpeechDomain#9 stale"
      )
    )
    for _ in 0..<20 { await Task.yield() }

    #expect(service.status == .idle)
    #expect(service.unavailableReason == nil)
  }

  private func makeService(
    localeIdentifier: String = "en-US",
    localeProvider: (@MainActor () -> String?)? = nil,
    authorization: FakeAuthorization = FakeAuthorization(),
    recognizer: FakeCallsignRecognizer?,
    audioCapture: FakeCallsignAudioCapture = FakeCallsignAudioCapture(),
    arbiter: AudioCaptureArbiter = AudioCaptureArbiter()
  ) -> CallsignDictationService {
    CallsignDictationService(
      localeIdentifier: localeIdentifier,
      localeProvider: localeProvider,
      authorization: authorization,
      recognizerFactory: { _ in recognizer },
      audioCapture: audioCapture,
      arbiter: arbiter
    )
  }

  private func makeService(
    localeIdentifier: String = "en-US",
    localeProvider: (@MainActor () -> String?)? = nil,
    authorization: FakeAuthorization = FakeAuthorization(),
    recognizer: FakeCallsignRecognizer = FakeCallsignRecognizer(),
    audioCapture: FakeCallsignAudioCapture = FakeCallsignAudioCapture(),
    arbiter: AudioCaptureArbiter = AudioCaptureArbiter()
  ) -> CallsignDictationService {
    makeService(
      localeIdentifier: localeIdentifier,
      localeProvider: localeProvider,
      authorization: authorization,
      recognizer: Optional(recognizer),
      audioCapture: audioCapture,
      arbiter: arbiter
    )
  }

  private static func wait(
    for predicate: @MainActor () -> Bool,
    // why: generous so a CPU-starved CI runner (the documented hosted-runner starvation) doesn't
    // time out before an async append Task is scheduled — it returns as soon as the condition holds,
    // so the headroom only costs wall time on a genuine failure, never on the passing path.
    timeout: Duration = .seconds(60)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return predicate()
  }

  private static func makeBuffer() -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
    buffer.frameLength = 16
    if let samples = buffer.floatChannelData?[0] {
      for index in 0..<Int(buffer.frameLength) {
        samples[index] = Float(index) / 16
      }
    }
    return buffer
  }
}

@MainActor
private final class FakeAuthorization: CallsignSpeechAuthorization {
  private let speechAllowed: Bool
  private let microphoneAllowed: Bool
  private let suspendSpeech: Bool
  private var speechContinuation: CheckedContinuation<Bool, Never>?
  private(set) var speechCallCount = 0
  private(set) var micCallCount = 0

  init(
    speechAllowed: Bool = true,
    microphoneAllowed: Bool = true,
    suspendSpeech: Bool = false
  ) {
    self.speechAllowed = speechAllowed
    self.microphoneAllowed = microphoneAllowed
    self.suspendSpeech = suspendSpeech
  }

  func requestSpeechAuthorization() async -> Bool {
    speechCallCount += 1
    guard suspendSpeech else { return speechAllowed }
    return await withCheckedContinuation { continuation in
      speechContinuation = continuation
    }
  }

  func requestMicrophonePermission() async -> Bool {
    micCallCount += 1
    return microphoneAllowed
  }

  func resumeSpeech(_ allowed: Bool) {
    speechContinuation?.resume(returning: allowed)
    speechContinuation = nil
  }
}

@MainActor
private final class FakeCallsignRecognizer: CallsignSpeechRecognizing {
  let isAvailable: Bool
  let supportsOnDeviceRecognition: Bool
  let task = FakeCallsignRecognitionTask()
  private let updatesOnStart: [CallsignRecognitionUpdate]
  private let onStart: () -> Void
  private var onUpdate: (@Sendable (CallsignRecognitionUpdate) -> Void)?
  var onAppend: (() -> Void)?
  private(set) var startCallCount = 0
  private(set) var appendedBuffers: [AVAudioPCMBuffer] = []
  private(set) var contextualStrings: [String] = []
  private(set) var endAudioCallCount = 0

  init(
    isAvailable: Bool = true,
    supportsOnDeviceRecognition: Bool = true,
    updatesOnStart: [CallsignRecognitionUpdate] = [],
    onStart: @escaping () -> Void = {}
  ) {
    self.isAvailable = isAvailable
    self.supportsOnDeviceRecognition = supportsOnDeviceRecognition
    self.updatesOnStart = updatesOnStart
    self.onStart = onStart
  }

  func startRecognition(
    contextualStrings: [String],
    onUpdate: @escaping @Sendable (CallsignRecognitionUpdate) -> Void
  )
    -> any CallsignRecognitionTasking
  {
    startCallCount += 1
    self.contextualStrings = contextualStrings
    self.onUpdate = onUpdate
    onStart()
    for update in updatesOnStart {
      onUpdate(update)
    }
    return task
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    appendedBuffers.append(buffer)
    onAppend?()
  }

  func endAudio() {
    endAudioCallCount += 1
  }

  func push(_ update: CallsignRecognitionUpdate) {
    onUpdate?(update)
  }
}

@MainActor
private final class FakeCallsignRecognitionTask: CallsignRecognitionTasking {
  private(set) var cancelCallCount = 0

  func cancel() {
    cancelCallCount += 1
  }
}

@MainActor
private final class FakeCallsignAudioCapture: CallsignAudioCapturing {
  private let startError: Error?
  private let buffersOnStart: [AVAudioPCMBuffer]
  private let onStart: () -> Void
  private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
  private(set) var startCallCount = 0
  private(set) var stopCallCount = 0
  private(set) var deactivationRequests: [Bool] = []

  init(
    startError: Error? = nil,
    buffersOnStart: [AVAudioPCMBuffer] = [],
    onStart: @escaping () -> Void = {}
  ) {
    self.startError = startError
    self.buffersOnStart = buffersOnStart
    self.onStart = onStart
  }

  func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
    startCallCount += 1
    onStart()
    if let startError { throw startError }
    self.onBuffer = onBuffer
    for buffer in buffersOnStart {
      onBuffer(buffer)
    }
  }

  func stop(deactivateSession: Bool) {
    stopCallCount += 1
    deactivationRequests.append(deactivateSession)
  }

  func emit(_ buffer: AVAudioPCMBuffer) {
    onBuffer?(buffer)
  }
}

private enum ScriptedError: LocalizedError {
  case captureStart

  var errorDescription: String? {
    switch self {
    case .captureStart:
      "scripted capture start failure"
    }
  }
}
