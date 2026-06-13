import Foundation
import WhisperKit

actor WhisperKitTranscriberAdapter: WhisperLiveTranscribing {
  private var pipeline: WhisperKit?

  func loadModel(folderURL: URL) async throws {
    pipeline = try await WhisperKit(
      WhisperKitConfig(
        modelFolder: folderURL.path,
        tokenizerFolder: folderURL,
        verbose: false,
        logLevel: .error,
        prewarm: false,
        load: true,
        download: false
      ))
  }

  func transcribe(samples: [Float], languageCode: String?) async throws -> [WhisperLiveSegment] {
    guard let pipeline else {
      throw WhisperKitTranscriberAdapterError.modelNotLoaded
    }
    let results = try await pipeline.transcribe(
      audioArray: samples,
      decodeOptions: DecodingOptions(
        task: .transcribe,
        language: languageCode,
        temperature: 0,
        wordTimestamps: true
      )
    )
    return results.flatMap(\.segments).map {
      WhisperLiveSegment(
        text: $0.text,
        startSeconds: Double($0.start),
        endSeconds: Double($0.end),
        avgLogProb: Double($0.avgLogprob)
      )
    }
  }
}

private enum WhisperKitTranscriberAdapterError: LocalizedError {
  case modelNotLoaded

  var errorDescription: String? {
    switch self {
    case .modelNotLoaded:
      "whisperkit-model-not-loaded"
    }
  }
}
