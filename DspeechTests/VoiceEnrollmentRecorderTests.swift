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

  @Test func busyCaptureSurfacesUnavailableWithoutRequestingPermissionOrStartingCapture() async {
    let arbiter = AudioCaptureArbiter()
    #expect(arbiter.acquire(.liveTranscription))
    let authorization = FakeEnrollmentAuthorization()
    let audioCapture = FakeEnrollmentAudioCapture()
    let recorder = makeRecorder(
      authorization: authorization,
      audioCapture: audioCapture,
      arbiter: arbiter
    )

    await recorder.start()

    #expect(
      recorder.status
        == .unavailable(
          "Audio capture is already in use. Stop transcription before recording an enrollment."))
    #expect(authorization.callCount == 0)
    #expect(audioCapture.startCallCount == 0)
    #expect(arbiter.activeClient == .liveTranscription)
  }

  @Test func microphoneDeniedSurfacesUnavailable() async {
    let authorization = FakeEnrollmentAuthorization(microphoneAllowed: false)
    let audioCapture = FakeEnrollmentAudioCapture()
    let recorder = makeRecorder(authorization: authorization, audioCapture: audioCapture)

    await recorder.start()

    #expect(recorder.status == .unavailable("No microphone access. Allow it in Settings."))
    #expect(authorization.callCount == 1)
    #expect(audioCapture.startCallCount == 0)
  }

  @Test func invalidInputFormatSurfacesUnavailable() async {
    let audioCapture = FakeEnrollmentAudioCapture(
      startError: VoiceEnrollmentCaptureError.invalidInputFormat
    )
    let recorder = makeRecorder(audioCapture: audioCapture)

    await recorder.start()

    #expect(recorder.status == .unavailable("The microphone is unavailable."))
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
    #expect(reason.contains("start recording"))
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

  @Test func stopReturnsDeliveredBufferSampleRate() async {
    let audioCapture = FakeEnrollmentAudioCapture(sampleRate: 44_100)
    let recorder = makeRecorder(audioCapture: audioCapture)
    await recorder.start()

    audioCapture.emit(Self.makeBuffer(values: [1, 2, 3], sampleRate: 22_050))
    let result = await recorder.stop()

    #expect(result?.samples == [1, 2, 3])
    #expect(result?.sampleRate == 22_050)
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

  @Test func stopRejectsSilenceShortOfMinimumVoicedDuration() async {
    let audioCapture = FakeEnrollmentAudioCapture()
    let recorder = makeRecorder(audioCapture: audioCapture, targetSeconds: 0.1)
    await recorder.start()

    audioCapture.emit(Self.makeBuffer(values: Self.silence(seconds: 0.2)))
    let result = await recorder.stop()

    #expect(result == nil)
    guard case .unavailable(let reason) = recorder.status else {
      Issue.record("expected unavailable status for insufficient voiced duration")
      return
    }
    #expect(reason.contains("enough of your voice"))
  }

  @Test func stopRejectsLowEnergyConstantNoiseShortOfMinimumVoicedDuration() async {
    let audioCapture = FakeEnrollmentAudioCapture()
    let recorder = makeRecorder(audioCapture: audioCapture, targetSeconds: 0.1)
    await recorder.start()

    audioCapture.emit(Self.makeBuffer(values: Self.constantNoise(seconds: 0.2, amplitude: 0.002)))
    let result = await recorder.stop()

    #expect(result == nil)
    guard case .unavailable(let reason) = recorder.status else {
      Issue.record("expected unavailable status for low-energy constant noise")
      return
    }
    #expect(reason.contains("enough of your voice"))
  }

  @Test func stopAcceptsSpeechLikeEnergyMeetingMinimumVoicedDuration() async {
    let audioCapture = FakeEnrollmentAudioCapture()
    let recorder = makeRecorder(audioCapture: audioCapture, targetSeconds: 0.1)
    await recorder.start()

    let samples = Self.speechLikeSamples(seconds: 0.12)
    audioCapture.emit(Self.makeBuffer(values: samples))
    let result = await recorder.stop()

    #expect(result?.samples == samples)
    #expect(result?.sampleRate == 16_000)
    #expect(recorder.status == .idle)
  }

  @Test func acceptsRealisticRecordingWithNaturalPausesAtProductionFloor() async {
    // why: real speech is only ~70% voiced (pauses between words), so a 4s recording registers
    // ~2.8s voiced. The PRODUCTION floor (VoiceEnrollmentRecorder.targetSeconds) must accept a
    // realistic recording rather than rejecting it as too short.
    let audioCapture = FakeEnrollmentAudioCapture()
    let recorder = makeRecorder(
      audioCapture: audioCapture, targetSeconds: VoiceEnrollmentRecorder.targetSeconds)
    await recorder.start()
    let samples = Self.speechWithPauses(wallClockSeconds: 4.0, voicedFraction: 0.7)
    audioCapture.emit(Self.makeBuffer(values: samples))
    let result = await recorder.stop()

    #expect(result != nil)
    #expect(recorder.status == .idle)
  }

  @Test func rejectsTwoSecondRecordingBelowProductionFloor() async {
    let audioCapture = FakeEnrollmentAudioCapture()
    let recorder = makeRecorder(
      audioCapture: audioCapture, targetSeconds: VoiceEnrollmentRecorder.targetSeconds)
    await recorder.start()
    let samples = Self.speechWithPauses(wallClockSeconds: 2.0, voicedFraction: 0.6)
    audioCapture.emit(Self.makeBuffer(values: samples))
    let result = await recorder.stop()

    #expect(result == nil)
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

  @Test func stopReleasesCaptureArbiter() async {
    let arbiter = AudioCaptureArbiter()
    let recorder = makeRecorder(arbiter: arbiter)

    await recorder.start()
    #expect(arbiter.activeClient == .voiceEnrollment)

    _ = await recorder.stop()

    #expect(arbiter.activeClient == nil)
  }

  @Test func stopWhenNoLongerArbiterHolderDoesNotDeactivateSession() async {
    let arbiter = AudioCaptureArbiter()
    let audioCapture = FakeEnrollmentAudioCapture()
    let recorder = makeRecorder(audioCapture: audioCapture, arbiter: arbiter)

    await recorder.start()
    #expect(arbiter.release(.voiceEnrollment))

    _ = await recorder.stop()

    #expect(audioCapture.deactivationRequests == [false])
    #expect(arbiter.activeClient == nil)
  }

  private func makeRecorder(
    authorization: FakeEnrollmentAuthorization = FakeEnrollmentAuthorization(),
    audioCapture: FakeEnrollmentAudioCapture = FakeEnrollmentAudioCapture(),
    arbiter: AudioCaptureArbiter = AudioCaptureArbiter(),
    targetSeconds: Double = 0.0001
  ) -> VoiceEnrollmentRecorder {
    VoiceEnrollmentRecorder(
      authorization: authorization,
      audioCapture: audioCapture,
      arbiter: arbiter,
      targetSeconds: targetSeconds
    )
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

  private static func makeBuffer(values: [Float], sampleRate: Double = 16_000) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
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

  private static func speechLikeSamples(
    seconds: Double,
    sampleRate: Double = 16_000
  ) -> [Float] {
    // why: the adaptive noise-floor VAD scores speech RELATIVE to the recent-minimum RMS, so a
    // constant-amplitude tone reads as steady noise and is never counted as speech. Real speech is
    // amplitude-modulated: prepend one quiet frame to seed a low floor, then a louder voiced carrier
    // that clears 2x the floor and counts toward the required voiced duration.
    let leadCount = Int((0.02 * sampleRate).rounded())
    let voicedCount = Int((seconds * sampleRate).rounded())
    let quiet = (0..<leadCount).map { index -> Float in
      Float(sin(Double(index % 64) / 64 * 2 * .pi) * 0.0005)
    }
    let voiced = (0..<voicedCount).map { index -> Float in
      Float(sin(Double(index % 64) / 64 * 2 * .pi) * 0.08)
    }
    return quiet + voiced
  }

  // why: model REAL speech — alternating voiced bursts and quiet gaps so the adaptive VAD sees a low
  // floor and clear speech, with only `voicedFraction` of the wall clock actually voiced. A 4s clip at
  // 0.7 yields ~2.8s voiced, exactly the case the old 4s-voiced floor wrongly rejected.
  private static func speechWithPauses(
    wallClockSeconds: Double, voicedFraction: Double, sampleRate: Double = 16_000
  ) -> [Float] {
    func tone(count: Int, amplitude: Float) -> [Float] {
      var samples = [Float](repeating: 0, count: count)
      for i in 0..<count {
        let phase = Double(i % 64) / 64.0 * 2.0 * Double.pi
        samples[i] = Float(sin(phase)) * amplitude
      }
      return samples
    }
    let burst = 0.35
    let gap = burst * (1 - voicedFraction) / max(voicedFraction, 0.01)
    var out: [Float] = []
    let lead = max(1, Int(0.02 * sampleRate))
    out += tone(count: lead, amplitude: 0.0005)
    var elapsed = Double(lead) / sampleRate
    var loud = true
    while elapsed < wallClockSeconds {
      let segment = loud ? burst : gap
      let count = max(1, Int(segment * sampleRate))
      out += tone(count: count, amplitude: loud ? 0.08 : 0.0008)
      elapsed += segment
      loud.toggle()
    }
    return out
  }

  private static func silence(seconds: Double, sampleRate: Double = 16_000) -> [Float] {
    Array(repeating: 0, count: Int((seconds * sampleRate).rounded()))
  }

  private static func constantNoise(
    seconds: Double,
    amplitude: Float,
    sampleRate: Double = 16_000
  ) -> [Float] {
    Array(repeating: amplitude, count: Int((seconds * sampleRate).rounded()))
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
  private(set) var deactivationRequests: [Bool] = []

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

  func stop(deactivateSession: Bool) {
    stopCallCount += 1
    deactivationRequests.append(deactivateSession)
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
