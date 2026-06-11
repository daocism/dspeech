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
    private let engine = AVAudioEngine()

    func events() -> AsyncStream<InputLevelMeterEvent> {
      AsyncStream<InputLevelMeterEvent> { continuation in
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // why: installTap with an invalid (0 Hz / 0-channel) format — which the
        // Simulator and a mic-denied device report — hard-crashes AVAudioEngine;
        // surface this as a typed meter failure instead of a silent zero bar.
        guard format.sampleRate > 0, format.channelCount > 0 else {
          continuation.yield(
            .failed(
              String(localized: "Couldn't test the level: the input audio format is unavailable.")))
          continuation.finish()
          return
        }
        input.removeTap(onBus: 0)
        // why: pass format:nil so the tap uses the input bus's OWN current format. Passing
        // a separately-read AVAudioFormat trips an NSException abort inside
        // AUGraphNodeBaseV3::CreateRecordingTap ("required condition is false:
        // format.sampleRate == hwFormat.sampleRate") whenever it doesn't match the live
        // hardware/render format (Simulator output-vs-render mismatch; a hw rate that
        // shifted after setActive). nil removes the mismatch; the guard above still bails
        // on a dead (0 Hz) input.
        //
        // why: the tap is nonisolated/realtime; it computes RMS synchronously and
        // yields only a Sendable Double — no AVAudioPCMBuffer escapes the callback,
        // so there is no actor-isolation hazard under Swift 6 complete concurrency.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
          continuation.yield(
            .level(AudioLevel.normalized(rms: AVAudioEngineInputLevelMeter.rms(of: buffer))))
        }
        engine.prepare()
        do {
          try engine.start()
        } catch {
          input.removeTap(onBus: 0)
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
      if engine.isRunning { engine.stop() }
      engine.inputNode.removeTap(onBus: 0)
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
