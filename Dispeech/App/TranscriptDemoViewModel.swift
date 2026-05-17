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
            confidence: 0.93,
            sourceLanguageCode: "en",
            source: .demo
        ),
        TranscriptSegment(
            text: "Speedbird 42, contact tower one one eight decimal seven.",
            confidence: 0.78,
            sourceLanguageCode: "en",
            source: .demo
        )
    ])
}
