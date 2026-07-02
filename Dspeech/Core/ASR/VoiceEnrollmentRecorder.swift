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

  // why: the minimum DETECTED-VOICED-speech floor — a lenient garbage filter, NOT the recording
  // length. Real speech is ~70% voiced (natural pauses between words), so a 4s recording the UI asks
  // for only registers ~2.9s voiced. A 4s VOICED floor would reject every normal ~4s recording as
  // "too short"; 1.5s of voiced speech still yields a usable WeSpeaker embedding, and the settings
  // UI guides ~4–5s wall-clock for a good one.
  static let targetSeconds: Double = 1.5

  private(set) var status: Status = .idle {
    didSet {
      switch status {
      case .idle:
        DspeechLog.voiceFilter.info("voice enrollment status=idle")
      case .starting:
        DspeechLog.voiceFilter.info("voice enrollment status=starting")
      case .recording:
        DspeechLog.voiceFilter.info("voice enrollment status=recording")
      case .unavailable(let reason):
        DspeechLog.voiceFilter.error("voice enrollment status=unavailable reason=\(reason)")
      }
    }
  }
  private(set) var collected: [Float] = []
  private(set) var captureSampleRate: Double = 16_000

  private let authorization: any VoiceEnrollmentMicrophoneAuthorizing
  private let audioCapture: any VoiceEnrollmentAudioCapturing
  private let arbiter: AudioCaptureArbiter
  private let targetSeconds: Double
  private var activeSessionID: UUID?
  private var captureContinuation: AsyncStream<VoiceEnrollmentCapturedSamples>.Continuation?
  private var consumeTask: Task<Void, Never>?
  private var captureLeaseAcquired = false
  private var captureStartAttempted = false
  private var captureStarted = false

  init(
    authorization: any VoiceEnrollmentMicrophoneAuthorizing =
      SystemVoiceEnrollmentMicrophoneAuthorization(),
    audioCapture: any VoiceEnrollmentAudioCapturing = AVAudioEngineVoiceEnrollmentCapture(),
    arbiter: AudioCaptureArbiter = .shared,
    targetSeconds: Double = VoiceEnrollmentRecorder.targetSeconds
  ) {
    self.authorization = authorization
    self.audioCapture = audioCapture
    self.arbiter = arbiter
    self.targetSeconds = max(targetSeconds, 0)
  }

  var isRecording: Bool { status == .recording }
  private var isActive: Bool { status == .starting || status == .recording }

  var unavailableReason: String? {
    if case .unavailable(let reason) = status { return reason }
    return nil
  }

  func start() async {
    guard !isActive else {
      DspeechLog.voiceFilter.debug("voice enrollment start ignored reason=already-active")
      return
    }
    DspeechLog.voiceFilter.info("voice enrollment start requested")
    guard arbiter.acquire(.voiceEnrollment) else {
      DspeechLog.voiceFilter.error("voice enrollment start failed reason=capture-session-busy")
      status = .unavailable(
        String(
          localized:
            "Audio capture is already in use. Stop transcription before recording an enrollment."))
      return
    }
    captureLeaseAcquired = true
    let sessionID = UUID()
    activeSessionID = sessionID
    status = .starting
    collected = []

    guard await authorization.requestMicrophonePermission() else {
      guard isCurrent(sessionID) else { return }
      DspeechLog.voiceFilter.error(
        "voice enrollment start failed reason=microphone-permission-denied"
      )
      activeSessionID = nil
      _ = releaseCaptureLease()
      status = .unavailable(String(localized: "No microphone access. Allow it in Settings."))
      return
    }
    guard isCurrent(sessionID) else { return }

    do {
      try beginCapture(sessionID: sessionID)
      guard isCurrent(sessionID) else { return }
      status = .recording
    } catch VoiceEnrollmentCaptureError.invalidInputFormat {
      DspeechLog.voiceFilter.error(
        "voice enrollment start failed reason=invalid-input-format"
      )
      await failAfterCapture(
        String(localized: "The microphone is unavailable."), sessionID: sessionID)
    } catch {
      DspeechLog.voiceFilter.error(
        "voice enrollment start failed reason=capture-start-failed error=\(error.localizedDescription)"
      )
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
        DspeechLog.voiceFilter.info("voice enrollment stop requested before recording")
        await cleanup(drainQueuedSamples: false)
        status = .idle
      }
      return nil
    }
    DspeechLog.voiceFilter.info("voice enrollment stop requested")
    await cleanup(drainQueuedSamples: true)
    status = .idle
    guard !collected.isEmpty else {
      DspeechLog.voiceFilter.error("voice enrollment stopped with no samples")
      return nil
    }
    guard hasMinimumVoicedDuration(samples: collected, sampleRate: captureSampleRate) else {
      DspeechLog.voiceFilter.error("voice enrollment stopped reason=insufficient-voiced-duration")
      status = .unavailable(insufficientVoicedDurationReason())
      return nil
    }
    DspeechLog.voiceFilter.info(
      "voice enrollment captured samples=\(self.collected.count, privacy: .public) sampleRate=\(self.captureSampleRate, privacy: .public)"
    )
    return (collected, captureSampleRate)
  }

  private func hasMinimumVoicedDuration(samples: [Float], sampleRate: Double) -> Bool {
    guard targetSeconds > 0 else { return true }
    guard sampleRate > 0, !samples.isEmpty else { return false }
    let frameSampleCount = max(1, Int((sampleRate * 0.02).rounded()))
    let segmenter = EnergySilenceSegmenter(
      minSpeechSeconds: targetSeconds,
      minSilenceSeconds: 0,
      maxWindowSeconds: .greatestFiniteMagnitude
    )
    var index = 0
    while index < samples.count {
      let endIndex = min(index + frameSampleCount, samples.count)
      let decision = segmenter.update(
        block: Array(samples[index..<endIndex]),
        sampleRate: sampleRate
      )
      if decision == .cutAfterSilence {
        return true
      }
      index = endIndex
    }
    return false
  }

  private func insufficientVoicedDurationReason() -> String {
    // why: guide the user by WALL-CLOCK (what they control), not the internal voiced-seconds floor —
    // telling them "1.5 seconds" would be misleading since real speech is only ~70% voiced.
    String(
      localized:
        "Didn't catch enough of your voice. Speak for about 5 seconds in a quiet spot, then tap Stop."
    )
  }

  private func beginCapture(sessionID: UUID) throws {
    let (captureStream, audioContinuation) = AsyncStream<VoiceEnrollmentCapturedSamples>.makeStream(
      bufferingPolicy: .unbounded
    )
    captureContinuation = audioContinuation
    consumeTask = Task { @MainActor [weak self] in
      for await captured in captureStream {
        guard let self, self.isCurrent(captured.sessionID) else { continue }
        self.captureSampleRate = captured.sampleRate
        self.collected.append(contentsOf: captured.samples)
      }
    }

    do {
      captureStartAttempted = true
      captureSampleRate = try audioCapture.start { buffer in
        guard let copy = buffer.dspeechDeepCopy(),
          let samples = AppleSpeechLiveTranscriptionEngine.monoFloatSamples(from: copy)
        else {
          return
        }
        audioContinuation.yield(
          VoiceEnrollmentCapturedSamples(
            sessionID: sessionID,
            samples: samples,
            sampleRate: copy.format.sampleRate
          )
        )
      }
      captureStarted = true
      DspeechLog.voiceFilter.info(
        "voice enrollment capture started sampleRate=\(self.captureSampleRate, privacy: .public)"
      )
    } catch {
      DspeechLog.voiceFilter.error(
        "voice enrollment capture failed error=\(error.localizedDescription)"
      )
      captureContinuation?.finish()
      captureContinuation = nil
      consumeTask?.cancel()
      consumeTask = nil
      throw error
    }
  }

  private func cleanup(drainQueuedSamples: Bool) async {
    DspeechLog.voiceFilter.info(
      "voice enrollment cleanup started drainQueuedSamples=\(drainQueuedSamples, privacy: .public)"
    )
    let sessionID = activeSessionID
    // why: stop the mic tap BEFORE finishing the sample stream. Finishing first means tail buffers the
    // tap is still delivering get yielded to an already-finished continuation and silently dropped —
    // which can push a borderline recording under the voiced-duration floor and surface a wrong "too
    // short" error. Stop the producer, then finish, then drain what it produced.
    let deactivateSession = releaseCaptureLease()
    if captureStarted || captureStartAttempted {
      audioCapture.stop(deactivateSession: deactivateSession)
    }
    captureStarted = false
    captureStartAttempted = false
    let continuation = captureContinuation
    captureContinuation = nil
    continuation?.finish()
    if drainQueuedSamples {
      await consumeTask?.value
    } else {
      consumeTask?.cancel()
    }
    consumeTask = nil
    if activeSessionID == sessionID {
      activeSessionID = nil
    }
    DspeechLog.voiceFilter.info("voice enrollment cleanup finished")
  }

  private func releaseCaptureLease() -> Bool {
    guard captureLeaseAcquired else { return false }
    captureLeaseAcquired = false
    return arbiter.release(.voiceEnrollment)
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
  let sampleRate: Double
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
  func stop(deactivateSession: Bool)
}

enum VoiceEnrollmentCaptureError: Error {
  case invalidInputFormat
}

@MainActor
private final class AVAudioEngineVoiceEnrollmentCapture: VoiceEnrollmentAudioCapturing {
  private let tapSession = AVAudioEngineTapSession()
  private var sessionActivated = false

  func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws -> Double {
    do {
      let session = AVAudioSession.sharedInstance()
      DspeechLog.voiceFilter.info("voice enrollment audio session activation requested")
      try session.setActive(true)
      sessionActivated = true
      DspeechLog.voiceFilter.info("voice enrollment audio session activation succeeded")

      let format: AVAudioFormat
      do {
        format = try tapSession.startTap(bufferSize: 2048, handler: onBuffer)
      } catch let error as AVAudioEngineTapSession.InvalidInputFormat {
        DspeechLog.voiceFilter.error(
          "voice enrollment audio tap install failed reason=invalid-input-format sampleRate=\(error.sampleRate, privacy: .public) channels=\(error.channelCount, privacy: .public)"
        )
        throw VoiceEnrollmentCaptureError.invalidInputFormat
      }
      DspeechLog.voiceFilter.info(
        "voice enrollment audio tap installed sampleRate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public)"
      )
      DspeechLog.voiceFilter.info("voice enrollment audio engine started")
      return format.sampleRate
    } catch {
      DspeechLog.voiceFilter.error(
        "voice enrollment audio capture start failed error=\(error.localizedDescription)"
      )
      stop(deactivateSession: false)
      throw error
    }
  }

  func stop(deactivateSession: Bool) {
    tapSession.stop()
    if deactivateSession, sessionActivated {
      DspeechLog.voiceFilter.info("voice enrollment audio session deactivation requested")
      do {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        DspeechLog.voiceFilter.info("voice enrollment audio session deactivation succeeded")
      } catch {
        DspeechLog.voiceFilter.error(
          "voice enrollment audio session deactivation failed error=\(error.localizedDescription)"
        )
      }
      sessionActivated = false
    }
  }
}
