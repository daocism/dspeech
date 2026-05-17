import Foundation
import Testing
@testable import Dspeech

struct TranscriptSegmentTests {
    @Test func lowConfidenceSegmentsRequireVerification() {
        let segment = TranscriptSegment(
            text: "Tower one one eight decimal seven",
            confidence: 0.70,
            sourceLanguageCode: "en",
            source: .demo
        )

        #expect(segment.requiresVerification)
    }

    @Test func highConfidenceSegmentsDoNotRequireVerification() {
        let segment = TranscriptSegment(
            text: "Descend and maintain three thousand",
            confidence: 0.94,
            sourceLanguageCode: "en",
            source: .demo
        )

        #expect(!segment.requiresVerification)
    }
}
