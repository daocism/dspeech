@preconcurrency import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class VoiceEnrollmentRecorder {
  enum Status: Equatable {
    case idle
    case starting
    case recording
    case unavailable(String)
  }

  static let targetSeconds: Double = 6

  private(set) var status: Status = .idle
  private(set) var collected: [Float] = []
  private(set) var captureSampleRate: Double = 16_000

  private let authorization: any VoiceEnrollmentMicrophoneAuthorizing
  private let audioCapture: any VoiceEnrollmentAudioCapturing
  private var activeSessionID: UUID?
  private var captureContinuation: AsyncStream<VoiceEnrollmentCapturedSamples>.Continuation?
  private var consumeTask: Task<Void, Never>?
  private var captureStarted = false

  init(
    authorization: any VoiceEnrollmentMicrophoneAuthorizing =
      SystemVoiceEnrollmentMicrophoneAuthorization(),
    audioCapture: any VoiceEnrollmentAudioCapturing = AVAudioEngineVoiceEnrollmentCapture()
  ) {
    self.authorization = authorization
    self.audioCapture = audioCapture
  }

  var isRecording: Bool { status == .recording }
  private var isActive: Bool { status == .starting || status == .recording }

  var unavailableReason: String? {
    if case .unavailable(let reason) = status { return reason }
    return nil
  }

  func start() async {
    guard !isActive else { return }
    let sessionID = UUID()
    activeSessionID = sessionID
    status = .starting
    collected = []

    guard await authorization.requestMicrophonePermission() else {
      guard isCurrent(sessionID) else { return }
      activeSessionID = nil
      status = .unavailable(String(localized: "No microphone access. Allow it in Settings."))
      return
    }
    guard isCurrent(sessionID) else { return }

    do {
      try beginCapture(sessionID: sessionID)
      guard isCurrent(sessionID) else { return }
      status = .recording
    } catch VoiceEnrollmentCaptureError.invalidInputFormat {
      await failAfterCapture(
        String(localized: "The microphone is unavailable."), sessionID: sessionID)
    } catch {
      await failAfterCapture(
        String(localized: "Couldn’t start recording: \(error.localizedDescription)"),
        sessionID: sessionID
      )
    }
  }

  @discardableResult
  func stop() async -> (samples: [Float], sampleRate: Double)? {
    guard isRecording else {
      if isActive {
        await cleanup(drainQueuedSamples: false)
        status = .idle
      }
      return nil
    }
    await cleanup(drainQueuedSamples: true)
    status = .idle
    guard !collected.isEmpty else { return nil }
    return (collected, captureSampleRate)
  }

  private func beginCapture(sessionID: UUID) throws {
    let (captureStream, audioContinuation) = AsyncStream<VoiceEnrollmentCapturedSamples>.makeStream(
      bufferingPolicy: .unbounded
    )
    captureContinuation = audioContinuation
    consumeTask = Task { @MainActor [weak self] in
      for await captured in captureStream {
        guard let self, self.isCurrent(captured.sessionID) else { continue }
        self.collected.append(contentsOf: captured.samples)
      }
    }

    do {
      captureSampleRate = try audioCapture.start { buffer in
        guard let copy = buffer.dspeechDeepCopy(),
          let samples = AppleSpeechLiveTranscriptionEngine.monoFloatSamples(from: copy)
        else {
          return
        }
        audioContinuation.yield(
          VoiceEnrollmentCapturedSamples(sessionID: sessionID, samples: samples)
        )
      }
      captureStarted = true
    } catch {
      captureContinuation?.finish()
      captureContinuation = nil
      consumeTask?.cancel()
      consumeTask = nil
      audioCapture.stop()
      throw error
    }
  }

  private func cleanup(drainQueuedSamples: Bool) async {
    let sessionID = activeSessionID
    let continuation = captureContinuation
    captureContinuation = nil
    continuation?.finish()
    if captureStarted {
      audioCapture.stop()
      captureStarted = false
    }
    if drainQueuedSamples {
      await consumeTask?.value
    } else {
      consumeTask?.cancel()
    }
    consumeTask = nil
    if activeSessionID == sessionID {
      activeSessionID = nil
    }
  }

  private func failAfterCapture(_ reason: String, sessionID: UUID) async {
    guard isCurrent(sessionID) else { return }
    await cleanup(drainQueuedSamples: false)
    status = .unavailable(reason)
  }

  private func isCurrent(_ sessionID: UUID) -> Bool {
    activeSessionID == sessionID
  }
}

private struct VoiceEnrollmentCapturedSamples: Sendable {
  let sessionID: UUID
  let samples: [Float]
}

@MainActor
protocol VoiceEnrollmentMicrophoneAuthorizing {
  func requestMicrophonePermission() async -> Bool
}

struct SystemVoiceEnrollmentMicrophoneAuthorization: VoiceEnrollmentMicrophoneAuthorizing {
  func requestMicrophonePermission() async -> Bool {
    if #available(iOS 17.0, *) {
      return await AVAudioApplication.requestRecordPermission()
    } else {
      return await withCheckedContinuation { continuation in
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          continuation.resume(returning: granted)
        }
      }
    }
  }
}

@MainActor
protocol VoiceEnrollmentAudioCapturing {
  func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws -> Double
  func stop()
}

enum VoiceEnrollmentCaptureError: Error {
  case invalidInputFormat
}

@MainActor
private final class AVAudioEngineVoiceEnrollmentCapture: VoiceEnrollmentAudioCapturing {
  private let audioEngine = AVAudioEngine()

  func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws -> Double {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
      try session.setActive(true, options: .notifyOthersOnDeactivation)

      let inputNode = audioEngine.inputNode
      let format = inputNode.outputFormat(forBus: 0)
      guard format.channelCount > 0, format.sampleRate > 0 else {
        throw VoiceEnrollmentCaptureError.invalidInputFormat
      }
      inputNode.removeTap(onBus: 0)
      inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { @Sendable buffer, _ in
        onBuffer(buffer)
      }
      audioEngine.prepare()
      try audioEngine.start()
      return format.sampleRate
    } catch {
      stop()
      throw error
    }
  }

  func stop() {
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    audioEngine.inputNode.removeTap(onBus: 0)
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}
