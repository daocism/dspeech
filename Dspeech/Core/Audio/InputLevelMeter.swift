import Foundation

enum AudioLevel {
  // why: map RMS amplitude (linear 0...1) to a 0...1 bar via a dB floor so quiet
  // room tone reads near 0 and normal speech fills the bar.
  static func normalized(rms: Float, floorDecibels: Float = -50) -> Double {
    guard rms > 0, rms.isFinite else { return 0 }
    let db = 20 * log10(rms)
    if db <= floorDecibels { return 0 }
    if db >= 0 { return 1 }
    return Double((db - floorDecibels) / -floorDecibels)
  }
}

protocol InputLevelMetering: Sendable {
  func events() -> AsyncStream<InputLevelMeterEvent>
  func stop()
}

enum InputLevelMeterEvent: Equatable, Sendable {
  case level(Double)
  case failed(String)
}

#if canImport(AVFAudio)
  @preconcurrency import AVFAudio

  final class AVAudioEngineInputLevelMeter: InputLevelMetering, @unchecked Sendable {
    // why: the realtime-tap hazards (format:nil, off-MainActor @Sendable handler, invalid-format
    // guard, idempotent stop) live once in AVAudioEngineTapSession. The meter's tap computes RMS
    // synchronously and yields only a Sendable Double — no AVAudioPCMBuffer escapes the callback.
    private let tapSession = AVAudioEngineTapSession()

    func events() -> AsyncStream<InputLevelMeterEvent> {
      AsyncStream<InputLevelMeterEvent> { continuation in
        do {
          try tapSession.startTap(bufferSize: 1024) { @Sendable buffer in
            continuation.yield(
              .level(AudioLevel.normalized(rms: AVAudioEngineInputLevelMeter.rms(of: buffer))))
          }
        } catch is AVAudioEngineTapSession.InvalidInputFormat {
          // why: an invalid (0 Hz / 0-channel) format — which the Simulator and a mic-denied
          // device report — surfaces as a typed meter failure instead of a silent zero bar.
          continuation.yield(
            .failed(
              String(localized: "Couldn't test the level: the input audio format is unavailable.")))
          continuation.finish()
          return
        } catch {
          tapSession.stop()
          continuation.yield(
            .failed(
              String(localized: "Couldn’t start the level check: \(error.localizedDescription)")))
          continuation.finish()
          return
        }
        continuation.onTermination = { [weak self] _ in
          self?.stop()
        }
      }
    }

    func stop() {
      tapSession.stop()
    }

    nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Float {
      guard let samples = AppleSpeechLiveTranscriptionEngine.monoFloatSamples(from: buffer),
        !samples.isEmpty
      else {
        return 0
      }
      var sumOfSquares: Float = 0
      for sample in samples {
        sumOfSquares += sample * sample
      }
      return (sumOfSquares / Float(samples.count)).squareRoot()
    }
  }
#endif
