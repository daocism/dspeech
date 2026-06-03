@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import Dspeech

@MainActor
struct VoiceEnrollmentRecorderTests {
  @Test func startSuccessBeginsCaptureAndMarksRecording() async {
    let audioCapture = FakeEnrollmentAudioCapture(sampleRate: 44_100)
    let recorder = makeRecorder(audioCapture: audioCapture)

    await recorder.start()

    #expect(recorder.status == .recording)
    #expect(recorder.isRecording)
    #expect(recorder.captureSampleRate == 44_100)
    #expect(audioCapture.startCallCount == 1)
  }

  @Test func microphoneDeniedSurfacesUnavailable() async {
    let authorization = FakeEnrollmentAuthorization(microphoneAllowed: false)
    let audioCapture = FakeEnrollmentAudioCapture()
    let recorder = makeRecorder(authorization: authorization, audioCapture: audioCapture)

    await recorder.start()

    #expect(recorder.status == .unavailable("Нет доступа к микрофону. Разрешите его в Настройках."))
    #expect(authorization.callCount == 1)
    #expect(audioCapture.startCallCount == 0)
  }

  @Test func invalidInputFormatSurfacesUnavailable() async {
    let audioCapture = FakeEnrollmentAudioCapture(
      startError: VoiceEnrollmentCaptureError.invalidInputFormat
    )
    let recorder = makeRecorder(audioCapture: audioCapture)

    await recorder.start()

    #expect(recorder.status == .unavailable("Микрофон недоступен."))
    #expect(audioCapture.startCallCount == 1)
    #expect(audioCapture.stopCallCount == 1)
  }

  @Test func engineStartFailureSurfacesUnavailableAndStopsCapture() async {
    let audioCapture = FakeEnrollmentAudioCapture(startError: ScriptedEnrollmentError.engineStart)
    let recorder = makeRecorder(audioCapture: audioCapture)

    await recorder.start()

    guard case .unavailable(let reason) = recorder.status else {
      Issue.record("expected unavailable status")
      return
    }
    #expect(reason.contains("Не удалось запустить запись"))
    #expect(audioCapture.startCallCount == 1)
    #expect(audioCapture.stopCallCount == 1)
  }

  @Test func duplicateStartWhilePermissionPendingUsesOneSession() async {
    let authorization = FakeEnrollmentAuthorization(suspend: true)
    let audioCapture = FakeEnrollmentAudioCapture()
    let recorder = makeRecorder(authorization: authorization, audioCapture: audioCapture)

    let firstStart = Task { await recorder.start() }
    #expect(await Self.wait(for: { authorization.callCount == 1 && recorder.status == .starting }))

    await recorder.start()
    #expect(authorization.callCount == 1)
    #expect(audioCapture.startCallCount == 0)

    authorization.resume(true)
    await firstStart.value

    #expect(recorder.status == .recording)
    #expect(audioCapture.startCallCount == 1)
  }

  @Test func stopReturnsDeliveredSamplesAndStopsCapture() async {
    let audioCapture = FakeEnrollmentAudioCapture()
    let recorder = makeRecorder(audioCapture: audioCapture)
    await recorder.start()

    audioCapture.emit(Self.makeBuffer(values: [1, 2, 3]))
    let result = await recorder.stop()

    #expect(result?.samples == [1, 2, 3])
    #expect(result?.sampleRate == 16_000)
    #expect(recorder.status == .idle)
    #expect(audioCapture.stopCallCount == 1)
  }

  @Test func stopWithNoSamplesReturnsNilAndStopsCapture() async {
    let audioCapture = FakeEnrollmentAudioCapture()
    let recorder = makeRecorder(audioCapture: audioCapture)
    await recorder.start()

    let result = await recorder.stop()

    #expect(result == nil)
    #expect(recorder.status == .idle)
    #expect(audioCapture.stopCallCount == 1)
  }

  @Test func lateBufferAfterStopIsIgnored() async {
    let audioCapture = FakeEnrollmentAudioCapture()
    let recorder = makeRecorder(audioCapture: audioCapture)
    await recorder.start()

    _ = await recorder.stop()
    audioCapture.emit(Self.makeBuffer(values: [4, 5, 6]))
    for _ in 0..<20 { await Task.yield() }

    #expect(recorder.collected.isEmpty)
  }

  @Test func stalePriorSessionBufferIsIgnoredAfterRestart() async {
    let audioCapture = FakeEnrollmentAudioCapture()
    let recorder = makeRecorder(audioCapture: audioCapture)
    await recorder.start()
    _ = await recorder.stop()

    await recorder.start()
    audioCapture.emit(Self.makeBuffer(values: [7, 8]), sessionIndex: 0)
    audioCapture.emit(Self.makeBuffer(values: [9, 10]), sessionIndex: 1)
    let result = await recorder.stop()

    #expect(result?.samples == [9, 10])
  }

  @Test func restartClearsOldSamples() async {
    let audioCapture = FakeEnrollmentAudioCapture()
    let recorder = makeRecorder(audioCapture: audioCapture)
    await recorder.start()
    audioCapture.emit(Self.makeBuffer(values: [11, 12]))
    #expect(await recorder.stop()?.samples == [11, 12])

    await recorder.start()

    #expect(recorder.collected.isEmpty)
    _ = await recorder.stop()
  }

  private func makeRecorder(
    authorization: FakeEnrollmentAuthorization = FakeEnrollmentAuthorization(),
    audioCapture: FakeEnrollmentAudioCapture = FakeEnrollmentAudioCapture()
  ) -> VoiceEnrollmentRecorder {
    VoiceEnrollmentRecorder(authorization: authorization, audioCapture: audioCapture)
  }

  private static func wait(
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

  private static func makeBuffer(values: [Float]) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(values.count)
    )!
    buffer.frameLength = AVAudioFrameCount(values.count)
    let samples = buffer.floatChannelData![0]
    for (index, value) in values.enumerated() {
      samples[index] = value
    }
    return buffer
  }
}

@MainActor
private final class FakeEnrollmentAuthorization: VoiceEnrollmentMicrophoneAuthorizing {
  private let microphoneAllowed: Bool
  private let suspend: Bool
  private var continuation: CheckedContinuation<Bool, Never>?
  private(set) var callCount = 0

  init(microphoneAllowed: Bool = true, suspend: Bool = false) {
    self.microphoneAllowed = microphoneAllowed
    self.suspend = suspend
  }

  func requestMicrophonePermission() async -> Bool {
    callCount += 1
    guard suspend else { return microphoneAllowed }
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func resume(_ allowed: Bool) {
    let continuation = continuation
    self.continuation = nil
    continuation?.resume(returning: allowed)
  }
}

@MainActor
private final class FakeEnrollmentAudioCapture: VoiceEnrollmentAudioCapturing {
  private let sampleRate: Double
  private let startError: Error?
  private var callbacks: [@Sendable (AVAudioPCMBuffer) -> Void] = []
  private(set) var startCallCount = 0
  private(set) var stopCallCount = 0

  init(sampleRate: Double = 16_000, startError: Error? = nil) {
    self.sampleRate = sampleRate
    self.startError = startError
  }

  func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws -> Double {
    startCallCount += 1
    callbacks.append(onBuffer)
    if let startError { throw startError }
    return sampleRate
  }

  func stop() {
    stopCallCount += 1
  }

  func emit(_ buffer: AVAudioPCMBuffer, sessionIndex: Int? = nil) {
    let index = sessionIndex ?? callbacks.indices.last
    guard let index, callbacks.indices.contains(index) else { return }
    callbacks[index](buffer)
  }
}

private enum ScriptedEnrollmentError: Error {
  case engineStart
}
