import Foundation
import Testing

@testable import Dspeech

// why: WhisperKitTranscriberAdapter wraps the real WhisperKit CoreML pipeline. The only branch
// reachable without staged models is the `pipeline == nil` guard in transcribe(_:languageCode:),
// which throws modelNotLoaded BEFORE any samples/languageCode are used. loadModel(...) and the
// happy decode + segment mapping require the real WhisperKit runtime and belong to the on-device
// eval lane, not this deterministic suite.
struct WhisperKitTranscriberAdapterTests {
  // why: the guard fires before samples/languageCode are read, so it must throw for EVERY input
  // shape — empty and populated samples, nil and concrete language hints alike.
  @Test(arguments: WhisperKitTranscriberAdapterTests.guardInputs)
  func shouldThrowModelNotLoadedWhenTranscribeCalledBeforeLoadModel(
    samples: [Float], languageCode: String?
  ) async {
    let adapter = WhisperKitTranscriberAdapter()
    do {
      _ = try await adapter.transcribe(samples: samples, languageCode: languageCode)
      Issue.record("expected modelNotLoaded to be thrown before any model is loaded")
    } catch {
      // why: the adapter's error enum is file-private, so assert on the LocalizedError slug it
      // surfaces rather than the concrete type — this is the string the engine layer reads.
      #expect(error.localizedDescription == "whisperkit-model-not-loaded")
    }
  }

  private static let guardInputs: [([Float], String?)] = [
    ([], nil),
    ([Float](repeating: 0.1, count: 16), "en"),
    ([0.0, -0.2, 0.5], "de-DE"),
    ([Float](repeating: 0, count: 16_000), "en-US"),
  ]
}
