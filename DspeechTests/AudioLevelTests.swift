@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import Dspeech

struct AudioLevelTests {
  @Test func silenceIsZero() {
    #expect(AudioLevel.normalized(rms: 0) == 0)
  }

  @Test func belowFloorIsZero() {
    #expect(AudioLevel.normalized(rms: 0.001) == 0)
  }

  @Test func fullScaleIsOne() {
    #expect(AudioLevel.normalized(rms: 1.0) == 1)
  }

  @Test func midRangeIsBetweenZeroAndOne() {
    let level = AudioLevel.normalized(rms: 0.0562)
    #expect(level > 0.4 && level < 0.6)
  }

  @Test func clampsNonFiniteToZero() {
    #expect(AudioLevel.normalized(rms: .nan) == 0)
    #expect(AudioLevel.normalized(rms: .infinity) == 0)
  }

  @Test func rmsMatchesMonoInterleavedStereoAndDeinterleavedStereo() {
    let samples = sineSamples(frames: 128, amplitude: 0.5)
    let mono = makeMonoBuffer(samples: samples)
    let interleavedStereo = makeInterleavedStereoBuffer(left: samples, right: samples)
    let deinterleavedStereo = makeDeinterleavedStereoBuffer(left: samples, right: samples)

    let monoRMS = AVAudioEngineInputLevelMeter.rms(of: mono)
    let interleavedRMS = AVAudioEngineInputLevelMeter.rms(of: interleavedStereo)
    let deinterleavedRMS = AVAudioEngineInputLevelMeter.rms(of: deinterleavedStereo)

    #expect(abs(monoRMS - interleavedRMS) < 0.0001)
    #expect(abs(monoRMS - deinterleavedRMS) < 0.0001)
  }

  @Test func rmsMixesChannelsBeforeMeasuring() {
    let samples = sineSamples(frames: 128, amplitude: 0.5)
    let silent = [Float](repeating: 0, count: samples.count)
    let mono = makeMonoBuffer(samples: samples)
    let rightOnlyStereo = makeInterleavedStereoBuffer(left: silent, right: samples)

    let monoRMS = AVAudioEngineInputLevelMeter.rms(of: mono)
    let mixedRMS = AVAudioEngineInputLevelMeter.rms(of: rightOnlyStereo)

    #expect(mixedRMS > 0)
    #expect(abs(mixedRMS - (monoRMS / 2)) < 0.0001)
  }

  private func sineSamples(frames: Int, amplitude: Float) -> [Float] {
    (0..<frames).map { frame in
      let phase = (Double(frame) / Double(frames)) * Double.pi * 2
      return amplitude * Float(sin(phase))
    }
  }

  private func makeMonoBuffer(samples: [Float]) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(samples.count)
    )!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let pointer = buffer.floatChannelData![0]
    for (frame, sample) in samples.enumerated() {
      pointer[frame] = sample
    }
    return buffer
  }

  private func makeInterleavedStereoBuffer(left: [Float], right: [Float]) -> AVAudioPCMBuffer {
    let frames = min(left.count, right.count)
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 2,
      interleaved: true
    )!
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(frames)
    )!
    buffer.frameLength = AVAudioFrameCount(frames)
    let pointer = buffer.floatChannelData![0]
    for frame in 0..<frames {
      pointer[frame * 2] = left[frame]
      pointer[frame * 2 + 1] = right[frame]
    }
    return buffer
  }

  private func makeDeinterleavedStereoBuffer(left: [Float], right: [Float]) -> AVAudioPCMBuffer {
    let frames = min(left.count, right.count)
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 2,
      interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(frames)
    )!
    buffer.frameLength = AVAudioFrameCount(frames)
    let channels = buffer.floatChannelData!
    for frame in 0..<frames {
      channels[0][frame] = left[frame]
      channels[1][frame] = right[frame]
    }
    return buffer
  }
}
