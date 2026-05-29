import Foundation

protocol SpeechRecognitionService: Sendable {
  func transcribe(_ audio: AsyncThrowingStream<AudioSampleBuffer, Error>) -> AsyncThrowingStream<
    TranscriptSegment, Error
  >
}
