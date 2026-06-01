import Foundation

struct AudioSampleBuffer: Equatable, Sendable {
  let timestamp: Date
  let sampleRate: Double
  let channelCount: Int
  let frameCount: Int
}

protocol AudioCaptureService: Sendable {
  func samples() -> AsyncThrowingStream<AudioSampleBuffer, Error>
}
