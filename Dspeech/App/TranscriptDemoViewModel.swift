import Foundation
import Observation

@MainActor
@Observable
final class TranscriptDemoViewModel {
  var segments: [TranscriptSegment]

  init(segments: [TranscriptSegment]) {
    self.segments = segments
  }

  static let demo = TranscriptDemoViewModel(segments: [
    TranscriptSegment(
      text: "N123AB, descend and maintain three thousand, expect ILS runway two seven approach.",
      translatedText:
        String(
          localized:
            "N123AB, descend and maintain three thousand, expect ILS approach runway two seven."),
      confidence: 0.93,
      sourceLanguageCode: "en",
      source: .demo
    ),
    TranscriptSegment(
      text: "Speedbird 42, contact tower one one eight decimal seven.",
      translatedText: String(
        localized: "Speedbird 42, contact tower on one one eight decimal seven."),
      confidence: 0.78,
      sourceLanguageCode: "en",
      source: .demo
    ),
    TranscriptSegment(
      text: "Delta 905, hold short of runway two seven, traffic on short final.",
      translatedText: String(
        localized: "Delta 905, hold short of runway two seven, traffic on short final."),
      confidence: 0.88,
      sourceLanguageCode: "en",
      source: .demo
    ),
  ])
}
