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
  func levels() -> AsyncStream<Double>
  func stop()
}

#if canImport(AVFAudio)
  @preconcurrency import AVFAudio

  final class AVAudioEngineInputLevelMeter: InputLevelMetering, @unchecked Sendable {
    private let engine = AVAudioEngine()

    func levels() -> AsyncStream<Double> {
      AsyncStream<Double> { continuation in
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // why: installTap with an invalid (0 Hz / 0-channel) format — which the
        // Simulator and a mic-denied device report — hard-crashes AVAudioEngine;
        // bail safely so the meter just reads nothing instead of taking down the app.
        guard format.sampleRate > 0, format.channelCount > 0 else {
          continuation.finish()
          return
        }
        input.removeTap(onBus: 0)
        // why: the tap is nonisolated/realtime; it computes RMS synchronously and
        // yields only a Sendable Double — no AVAudioPCMBuffer escapes the callback,
        // so there is no actor-isolation hazard under Swift 6 complete concurrency.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
          continuation.yield(
            AudioLevel.normalized(rms: AVAudioEngineInputLevelMeter.rms(of: buffer)))
        }
        engine.prepare()
        do {
          try engine.start()
        } catch {
          input.removeTap(onBus: 0)
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

    private nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Float {
      guard buffer.format.commonFormat == .pcmFormatFloat32,
        let channelData = buffer.floatChannelData
      else { return 0 }
      let frames = Int(buffer.frameLength)
      guard frames > 0 else { return 0 }
      let samples = channelData[0]
      var sumOfSquares: Float = 0
      for index in 0..<frames {
        let sample = samples[index]
        sumOfSquares += sample * sample
      }
      return (sumOfSquares / Float(frames)).squareRoot()
    }
  }
#endif
