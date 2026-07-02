@preconcurrency import AVFoundation
import Testing

@testable import Dspeech

@MainActor
struct LiveAudioCaptureConduitTests {
  @Test func arbiterBusyStartFailsWithCaptureSessionBusy() {
    let arbiter = AudioCaptureArbiter()
    #expect(arbiter.acquire(.callsignDictation))
    let conduit = LiveAudioCaptureConduit(
      arbiter: arbiter,
      audioSession: SpyConduitAudioSession()
    )

    do {
      _ = try conduit.start(onConfigurationChange: {}, onFailure: { _ in })
      #expect(Bool(false), "busy capture should throw")
    } catch {
      #expect(error.localizedDescription == "capture-session-busy")
    }

    #expect(arbiter.activeClient == .callsignDictation)
  }

  @Test func stopReleasesArbiterAndDeactivatesWhenLiveCaptureIsHolder() {
    let arbiter = AudioCaptureArbiter()
    let audioSession = SpyConduitAudioSession()
    let conduit = LiveAudioCaptureConduit(arbiter: arbiter, audioSession: audioSession)
    _ = conduit.primeStartedForTesting(acquireCapture: true)
    #expect(arbiter.activeClient == .liveTranscription)

    let result = conduit.stop()

    #expect(result.deactivationFailureSlug == nil)
    #expect(arbiter.activeClient == nil)
    #expect(audioSession.setActiveCalls == [.inactive(options: .notifyOthersOnDeactivation)])
  }

  @Test func failedSessionActivationReleasesArbiter() {
    let arbiter = AudioCaptureArbiter()
    let audioSession = SpyConduitAudioSession(activationError: SpyConduitAudioSessionError.denied)
    let conduit = LiveAudioCaptureConduit(arbiter: arbiter, audioSession: audioSession)

    do {
      _ = try conduit.start(onConfigurationChange: {}, onFailure: { _ in })
      #expect(Bool(false), "activation failure should throw")
    } catch {
      #expect(error.localizedDescription == "activation-denied")
    }

    #expect(audioSession.configuredForLiveRecording)
    #expect(arbiter.activeClient == nil)
  }

  @Test func streamFinishesOnStopAndDropsLaterBuffers() async {
    let conduit = LiveAudioCaptureConduit(
      arbiter: AudioCaptureArbiter(),
      audioSession: SpyConduitAudioSession()
    )
    let stream = conduit.primeStartedForTesting(acquireCapture: true)
    var iterator = stream.makeAsyncIterator()
    conduit.yieldCapturedBufferForTesting(makeCapturedBuffer(fill: 0.25))

    guard let captured = await iterator.next() else {
      #expect(Bool(false), "capture stream did not emit before stop")
      return
    }
    #expect(captured.samples == [0.25, 0.25])

    _ = conduit.stop()
    conduit.yieldCapturedBufferForTesting(makeCapturedBuffer(fill: 0.5))

    let afterStop = await iterator.next()
    if afterStop != nil {
      #expect(Bool(false), "capture stream emitted after stop")
    }
  }

  @Test func doubleStartThrowsCaptureAlreadyRunningWithoutReconfiguringSession() {
    let audioSession = SpyConduitAudioSession()
    let conduit = LiveAudioCaptureConduit(
      arbiter: AudioCaptureArbiter(),
      audioSession: audioSession
    )
    _ = conduit.primeStartedForTesting(acquireCapture: true)

    do {
      _ = try conduit.start(onConfigurationChange: {}, onFailure: { _ in })
      #expect(Bool(false), "double start should throw")
    } catch {
      #expect(error.localizedDescription == "capture-already-running")
    }

    #expect(!audioSession.configuredForLiveRecording)
    _ = conduit.stop()
  }

  private func makeCapturedBuffer(fill: Float) -> LiveCapturedAudioBuffer {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
    buffer.frameLength = 2
    buffer.floatChannelData![0][0] = fill
    buffer.floatChannelData![0][1] = fill
    return LiveCapturedAudioBuffer(buffer: buffer, samples: [fill, fill], sampleRate: 16_000)
  }
}

// why: the tap-session primitive's I/O-bearing paths (format guard, installTap, engine start)
// need real audio hardware, so they are exercised on device, not here. Its one hardware-free
// contract — idempotent teardown — is pinned below so a refactor can't reintroduce the
// "stop() must be safe when never started / called twice" hazard the four wrappers rely on.
@MainActor
struct AVAudioEngineTapSessionTests {
  @Test func freshSessionIsNotRunning() {
    let session = AVAudioEngineTapSession()
    #expect(!session.isRunning)
  }

  @Test func stopIsIdempotentWhenNeverStarted() {
    let session = AVAudioEngineTapSession()
    session.stop()
    session.stop()
    #expect(!session.isRunning)
  }
}

private enum SpyConduitAudioSessionError: Error, LocalizedError {
  case denied

  var errorDescription: String? {
    switch self {
    case .denied:
      return "activation-denied"
    }
  }
}

@MainActor
private final class SpyConduitAudioSession: LiveAudioSessionManaging {
  enum SetActiveCall: Equatable {
    case active(options: AVAudioSession.SetActiveOptions)
    case inactive(options: AVAudioSession.SetActiveOptions)
  }

  private(set) var configuredForLiveRecording = false
  private(set) var setActiveCalls: [SetActiveCall] = []
  private let activationError: (any Error)?

  init(activationError: (any Error)? = nil) {
    self.activationError = activationError
  }

  func configureForLiveRecording() throws {
    configuredForLiveRecording = true
  }

  func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
    setActiveCalls.append(active ? .active(options: options) : .inactive(options: options))
    if active, let activationError {
      throw activationError
    }
  }
}
