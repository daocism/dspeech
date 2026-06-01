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
}
