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
            translatedText: "Борт N123AB, снижайтесь и сохраняйте три тысячи, ожидайте заход по ILS на полосу два семь.",
            confidence: 0.93,
            sourceLanguageCode: "en",
            source: .demo
        ),
        TranscriptSegment(
            text: "Speedbird 42, contact tower one one eight decimal seven.",
            translatedText: "Спидберд 42, работайте с вышкой на сто восемнадцать запятая семь.",
            confidence: 0.78,
            sourceLanguageCode: "en",
            source: .demo
        ),
        TranscriptSegment(
            text: "Delta 905, hold short of runway two seven, traffic on short final.",
            translatedText: "Дельта 905, остановиться перед полосой два семь, борт на коротком финале.",
            confidence: 0.88,
            sourceLanguageCode: "en",
            source: .demo
        )
    ])
}
