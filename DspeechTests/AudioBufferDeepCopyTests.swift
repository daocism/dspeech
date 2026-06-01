import AVFoundation
import Testing

@testable import Dspeech

struct AudioBufferDeepCopyTests {
  private func makeFloatBuffer(frames: AVAudioFrameCount, fill: Float) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16000,
      channels: 1,
      interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    if frames > 0 {
      let pointer = buffer.floatChannelData![0]
      for index in 0..<Int(frames) { pointer[index] = fill }
    }
    return buffer
  }

  @Test func deepCopyPreservesSamplesAndShape() {
    let source = makeFloatBuffer(frames: 512, fill: 0.5)
    let copy = source.dspeechDeepCopy()
    #expect(copy != nil)
    #expect(copy?.frameLength == 512)
    #expect(copy?.format.sampleRate == 16000)
    #expect(copy?.format.channelCount == 1)
    let copied = copy!.floatChannelData![0]
    #expect(copied[0] == 0.5)
    #expect(copied[511] == 0.5)
  }

  @Test func deepCopyIsIndependentOfRecycledSource() {
    // why: AVAudioEngine recycles the tap buffer storage across callbacks; the copy
    // handed to async work must not observe a later overwrite of the source.
    let source = makeFloatBuffer(frames: 256, fill: 1.0)
    let copy = source.dspeechDeepCopy()!
    let sourcePointer = source.floatChannelData![0]
    for index in 0..<256 { sourcePointer[index] = -9.0 }
    let copied = copy.floatChannelData![0]
    #expect(copied[0] == 1.0)
    #expect(copied[255] == 1.0)
  }

  @Test func deepCopyHandlesZeroFrames() {
    let source = makeFloatBuffer(frames: 0, fill: 0)
    let copy = source.dspeechDeepCopy()
    #expect(copy?.frameLength == 0)
  }

  private func makeInterleavedStereoBuffer(
    frames: AVAudioFrameCount, left: Float, right: Float
  ) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 2, interleaved: true)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let pointer = buffer.floatChannelData![0]
    for frame in 0..<Int(frames) {
      pointer[frame * 2] = left
      pointer[frame * 2 + 1] = right
    }
    return buffer
  }

  private func makeDeinterleavedStereoBuffer(
    frames: AVAudioFrameCount, left: Float, right: Float
  ) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 2, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let channels = buffer.floatChannelData!
    for frame in 0..<Int(frames) {
      channels[0][frame] = left
      channels[1][frame] = right
    }
    return buffer
  }

  private func makeInt16MonoBuffer(frames: AVAudioFrameCount, value: Int16) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let pointer = buffer.int16ChannelData![0]
    for index in 0..<Int(frames) { pointer[index] = value }
    return buffer
  }

  @Test func deepCopyPreservesInterleavedStereoAndIsIndependent() {
    // why: external USB / line-in audio interfaces (the cockpit-cable path) often
    // present interleaved buffers; the copy must keep both channels and survive a
    // recycled-source overwrite.
    let source = makeInterleavedStereoBuffer(frames: 128, left: 0.3, right: 0.7)
    let copy = source.dspeechDeepCopy()!
    #expect(copy.frameLength == 128)
    let sourcePointer = source.floatChannelData![0]
    for index in 0..<256 { sourcePointer[index] = -1.0 }
    let copied = copy.floatChannelData![0]
    #expect(copied[0] == 0.3)
    #expect(copied[1] == 0.7)
    #expect(copied[254] == 0.3)
    #expect(copied[255] == 0.7)
  }

  @Test func deepCopyPreservesDeinterleavedStereo() {
    let source = makeDeinterleavedStereoBuffer(frames: 64, left: 0.1, right: 0.9)
    let copy = source.dspeechDeepCopy()!
    #expect(copy.frameLength == 64)
    let channels = copy.floatChannelData!
    #expect(channels[0][63] == 0.1)
    #expect(channels[1][63] == 0.9)
  }

  @Test func deepCopyPreservesInt16Samples() {
    let source = makeInt16MonoBuffer(frames: 100, value: 12345)
    let copy = source.dspeechDeepCopy()!
    #expect(copy.frameLength == 100)
    let copied = copy.int16ChannelData![0]
    #expect(copied[0] == 12345)
    #expect(copied[99] == 12345)
  }

  @Test func monoFloatSamplesMixesInterleavedStereo() {
    // why: frame-distinct L/R values so a per-channel (deinterleaved-stride) read
    // would mis-mix; only the correct interleaved indexing yields frame + 0.5.
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 2, interleaved: true)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)!
    buffer.frameLength = 8
    let pointer = buffer.floatChannelData![0]
    for frame in 0..<8 {
      pointer[frame * 2] = Float(frame)
      pointer[frame * 2 + 1] = Float(frame) + 1
    }
    let mono = AppleSpeechLiveTranscriptionEngine.monoFloatSamples(from: buffer)
    #expect(mono?.count == 8)
    for frame in 0..<8 {
      #expect(abs((mono?[frame] ?? -999) - (Float(frame) + 0.5)) < 0.0001)
    }
  }

  @Test func monoFloatSamplesMixesDeinterleavedStereo() {
    let source = makeDeinterleavedStereoBuffer(frames: 16, left: 0.6, right: 0.0)
    let mono = AppleSpeechLiveTranscriptionEngine.monoFloatSamples(from: source)
    #expect(mono?.count == 16)
    #expect(mono?.allSatisfy { abs($0 - 0.3) < 0.0001 } == true)
  }
}
