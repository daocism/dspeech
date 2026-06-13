@preconcurrency import AVFoundation
import Foundation

struct LiveCapturedAudioBuffer: @unchecked Sendable {
  let buffer: AVAudioPCMBuffer
  let samples: [Float]
  let sampleRate: Double
}

struct LiveEngineCleanupResult {
  let deactivationFailureSlug: String?
}

enum LiveEngineError: LocalizedError {
  case captureSessionBusy
  case captureAlreadyRunning
  case invalidInputFormat
  case capturePipelineUnavailable
  case audioEngineNotRunningAfterConfigurationChange

  var errorDescription: String? {
    switch self {
    case .captureSessionBusy:
      return "capture-session-busy"
    case .captureAlreadyRunning:
      return "capture-already-running"
    case .invalidInputFormat:
      return "invalid-input-format"
    case .capturePipelineUnavailable:
      return "capture-pipeline-unavailable"
    case .audioEngineNotRunningAfterConfigurationChange:
      return "audio-engine-not-running-after-configuration-change"
    }
  }
}

@MainActor
protocol LiveAudioSessionManaging: AnyObject {
  func configureForLiveRecording() throws
  func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

@MainActor
final class SystemLiveAudioSession: LiveAudioSessionManaging {
  private let session: AVAudioSession

  init(session: AVAudioSession = .sharedInstance()) {
    self.session = session
  }

  func configureForLiveRecording() throws {
    try LiveAudioSessionRouting.configureRecordCategory(session)
  }

  func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
    try session.setActive(active, options: options)
  }
}

@MainActor
final class LiveAudioCaptureConduit {
  private let arbiter: AudioCaptureArbiter
  private let audioSession: any LiveAudioSessionManaging
  private var audioEngine = AVAudioEngine()
  private var engineConfigurationObserver: NSObjectProtocol?
  private var captureContinuation: AsyncStream<LiveCapturedAudioBuffer>.Continuation?

  init(
    arbiter: AudioCaptureArbiter = .shared,
    audioSession: any LiveAudioSessionManaging = SystemLiveAudioSession()
  ) {
    self.arbiter = arbiter
    self.audioSession = audioSession
  }

  var isEngineRunning: Bool { audioEngine.isRunning }

  // why: begins session + engine + tap; returns the FIFO buffer stream.
  func start(
    onConfigurationChange: @escaping @MainActor () -> Void,
    onFailure: @escaping @MainActor (String) -> Void
  ) throws -> AsyncStream<LiveCapturedAudioBuffer> {
    guard captureContinuation == nil else {
      throw LiveEngineError.captureAlreadyRunning
    }
    guard arbiter.acquire(.liveTranscription) else {
      throw LiveEngineError.captureSessionBusy
    }
    let (captureStream, audioContinuation) = AsyncStream<LiveCapturedAudioBuffer>.makeStream(
      bufferingPolicy: .unbounded
    )
    captureContinuation = audioContinuation
    do {
      try beginAudioSession()
      try startEngine(
        onConfigurationChange: onConfigurationChange,
        onFailure: onFailure
      )
      return captureStream
    } catch {
      _ = stop()
      throw error
    }
  }

  func stop() -> LiveEngineCleanupResult {
    removeEngineConfigurationObserver()
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    audioEngine.inputNode.removeTap(onBus: 0)
    captureContinuation?.finish()
    captureContinuation = nil
    var deactivationFailure: String?
    if arbiter.release(.liveTranscription) {
      DspeechLog.engine.info("live audio session deactivation requested")
      do {
        try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        DspeechLog.engine.info("live audio session deactivation succeeded")
      } catch {
        deactivationFailure = "audio-session-deactivation-failed: \(error.localizedDescription)"
        DspeechLog.engine.error(
          "live audio session deactivation failed error=\(error.localizedDescription)"
        )
      }
    }
    return LiveEngineCleanupResult(deactivationFailureSlug: deactivationFailure)
  }

  private func beginAudioSession() throws {
    DspeechLog.engine.info("live audio session configure requested")
    do {
      try audioSession.configureForLiveRecording()
      DspeechLog.engine.info("live audio session configure succeeded")
    } catch {
      DspeechLog.engine.error(
        "live audio session configure failed error=\(error.localizedDescription)"
      )
      throw error
    }

    DspeechLog.engine.info("live audio session activation requested")
    do {
      try audioSession.setActive(true, options: [])
      DspeechLog.engine.info("live audio session activation succeeded")
    } catch {
      DspeechLog.engine.error(
        "live audio session activation failed error=\(error.localizedDescription)"
      )
      throw error
    }
  }

  private func startEngine(
    onConfigurationChange: @escaping @MainActor () -> Void,
    onFailure: @escaping @MainActor (String) -> Void
  ) throws {
    DspeechLog.engine.info("live audio engine start requested")
    audioEngine = AVAudioEngine()
    try startCurrentAudioEngine()
    installEngineConfigurationObserver(
      onConfigurationChange: onConfigurationChange,
      onFailure: onFailure
    )
    DspeechLog.engine.info("live audio engine started")
  }

  private func startCurrentAudioEngine() throws {
    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)
    // why: on some device routes (mic not yet granted, mid route-change, certain
    // external interfaces) the input format reports 0 Hz / 0 channels; installing a
    // tap with it throws deep inside CoreAudio. Surface it as an explicit failure.
    guard recordingFormat.channelCount > 0, recordingFormat.sampleRate > 0 else {
      DspeechLog.engine.error(
        "live audio tap install failed slug=invalid-input-format sampleRate=\(recordingFormat.sampleRate, privacy: .public) channels=\(recordingFormat.channelCount, privacy: .public)"
      )
      throw LiveEngineError.invalidInputFormat
    }

    guard let audioContinuation = captureContinuation else {
      DspeechLog.engine.error("live audio tap install failed slug=capture-pipeline-unavailable")
      throw LiveEngineError.capturePipelineUnavailable
    }

    inputNode.removeTap(onBus: 0)
    // why: format:nil — the tap uses the input bus's OWN current format. Passing a
    // separately-read AVAudioFormat (recordingFormat) trips an NSException abort inside
    // AUGraphNodeBaseV3::CreateRecordingTap ("required condition is false:
    // format.sampleRate == hwFormat.sampleRate") when it doesn't match the live hardware
    // rate — which .measurement mode reconfigures, so the cached value is stale at
    // tap-build time. nil removes the mismatch; the guard above still fails-fast on a dead
    // (0 Hz / 0-channel) input. recordingFormat is kept only for that guard.
    //
    // why: the `@Sendable` on this block is LOAD-BEARING, not cosmetic. This type is
    // @MainActor, so a bare closure literal here inherits @MainActor isolation; when
    // AVFAudio invokes it on its realtime RealtimeMessenger thread, Swift asserts
    // swift_task_isCurrentExecutor(MainActor) → false → dispatch_assert_queue_fail
    // (EXC_BREAKPOINT) and the app crashes on the first captured buffer. `@Sendable`
    // forces the block nonisolated so it legally runs off-MainActor. It captures only
    // the Sendable continuation (never self / @MainActor state), deep-copies the
    // recycled buffer, and yields it in capture order for the @MainActor consumer.
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
      guard let copy = buffer.dspeechDeepCopy() else { return }
      let samples = LiveAudioCaptureConduit.monoFloatSamples(from: copy) ?? []
      audioContinuation.yield(
        LiveCapturedAudioBuffer(buffer: copy, samples: samples, sampleRate: copy.format.sampleRate)
      )
    }
    DspeechLog.engine.info(
      "live audio tap installed sampleRate=\(recordingFormat.sampleRate, privacy: .public) channels=\(recordingFormat.channelCount, privacy: .public)"
    )

    audioEngine.prepare()
    try audioEngine.start()
    DspeechLog.engine.info("live audio engine run loop started")
  }

  private func installEngineConfigurationObserver(
    onConfigurationChange: @escaping @MainActor () -> Void,
    onFailure: @escaping @MainActor (String) -> Void
  ) {
    removeEngineConfigurationObserver()
    engineConfigurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: audioEngine,
      queue: nil
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.handleEngineConfigurationChange(
          onConfigurationChange: onConfigurationChange,
          onFailure: onFailure
        )
      }
    }
  }

  private func removeEngineConfigurationObserver() {
    if let engineConfigurationObserver {
      NotificationCenter.default.removeObserver(engineConfigurationObserver)
      self.engineConfigurationObserver = nil
    }
  }

  private func handleEngineConfigurationChange(
    onConfigurationChange: @escaping @MainActor () -> Void,
    onFailure: @escaping @MainActor (String) -> Void
  ) {
    guard captureContinuation != nil else { return }
    DspeechLog.engine.info("live audio engine configuration-change rebuild requested")
    do {
      audioEngine.inputNode.removeTap(onBus: 0)
      try startCurrentAudioEngine()
      guard audioEngine.isRunning else {
        throw LiveEngineError.audioEngineNotRunningAfterConfigurationChange
      }
      DspeechLog.engine.info("live audio engine configuration-change rebuild succeeded")
      onConfigurationChange()
    } catch {
      let slug = "engine-configuration-change-failed: \(error.localizedDescription)"
      _ = stop()
      DspeechLog.engine.error(
        "live audio engine configuration-change rebuild failed error=\(error.localizedDescription)"
      )
      onFailure(slug)
    }
  }

  nonisolated static func monoFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
    guard buffer.format.commonFormat == .pcmFormatFloat32,
      let channelData = buffer.floatChannelData
    else {
      return nil
    }
    let frameLength = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard frameLength > 0, channelCount > 0 else { return nil }

    if channelCount == 1 {
      return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }

    var mono = [Float](repeating: 0, count: frameLength)
    let scale = 1.0 / Float(channelCount)
    if buffer.format.isInterleaved {
      // why: interleaved multichannel lives in a single pointer as L,R,L,R…; index
      // by frame*channelCount + channel, not per-channel pointers (which would be
      // out of bounds for interleaved external-interface input).
      let pointer = channelData[0]
      for frame in 0..<frameLength {
        var sum: Float = 0
        for channel in 0..<channelCount {
          sum += pointer[frame * channelCount + channel]
        }
        mono[frame] = sum * scale
      }
    } else {
      for channel in 0..<channelCount {
        let pointer = channelData[channel]
        for frame in 0..<frameLength {
          mono[frame] += pointer[frame]
        }
      }
      for frame in 0..<frameLength {
        mono[frame] *= scale
      }
    }
    return mono
  }

  #if DEBUG
    func primeStartedForTesting(acquireCapture: Bool) -> AsyncStream<LiveCapturedAudioBuffer> {
      let (captureStream, audioContinuation) = AsyncStream<LiveCapturedAudioBuffer>.makeStream(
        bufferingPolicy: .unbounded
      )
      captureContinuation = audioContinuation
      if acquireCapture {
        _ = arbiter.acquire(.liveTranscription)
      }
      return captureStream
    }

    func yieldCapturedBufferForTesting(_ captured: LiveCapturedAudioBuffer) {
      captureContinuation?.yield(captured)
    }
  #endif
}

extension AVAudioPCMBuffer {
  // why: AVAudioEngine reuses the tap's buffer storage across callbacks, so any
  // buffer handed to async work must be deep-copied synchronously inside the tap or
  // its samples are overwritten before they are read.
  func dspeechDeepCopy() -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
      return nil
    }
    copy.frameLength = frameLength
    let frames = Int(frameLength)
    let channels = Int(format.channelCount)
    guard frames > 0, channels > 0 else { return copy }
    // why: interleaved buffers expose ONE channel pointer holding frames*channels
    // samples (L,R,L,R…); deinterleaved expose `channels` pointers of `frames` each.
    // Indexing per-channel on an interleaved buffer reads out of bounds and copies
    // only half the audio — silent corruption on external USB / line-in routes.
    let pointerCount = format.isInterleaved ? 1 : channels
    let elementsPerPointer = format.isInterleaved ? frames * channels : frames
    if let source = floatChannelData, let destination = copy.floatChannelData {
      for index in 0..<pointerCount {
        destination[index].update(from: source[index], count: elementsPerPointer)
      }
    } else if let source = int16ChannelData, let destination = copy.int16ChannelData {
      for index in 0..<pointerCount {
        destination[index].update(from: source[index], count: elementsPerPointer)
      }
    } else if let source = int32ChannelData, let destination = copy.int32ChannelData {
      for index in 0..<pointerCount {
        destination[index].update(from: source[index], count: elementsPerPointer)
      }
    } else {
      return nil
    }
    return copy
  }
}
