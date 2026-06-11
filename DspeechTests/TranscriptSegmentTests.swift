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

  @Test func confidenceExactlyAtVerificationThresholdDoesNotRequireVerification() {
    let segment = TranscriptSegment(
      text: "Cleared for takeoff runway two seven",
      confidence: 0.82,
      sourceLanguageCode: "en",
      source: .liveATC
    )

    #expect(!segment.requiresVerification)
  }

  @Test func confidenceOneUlpBelowVerificationThresholdRequiresVerification() {
    let segment = TranscriptSegment(
      text: "Hold short runway two seven",
      confidence: 0.82.nextDown,
      sourceLanguageCode: "en",
      source: .liveATC
    )

    #expect(segment.requiresVerification)
  }

  @Test func confidenceOneUlpAboveVerificationThresholdDoesNotRequireVerification() {
    let segment = TranscriptSegment(
      text: "Contact tower one one eight decimal seven",
      confidence: 0.82.nextUp,
      sourceLanguageCode: "en",
      source: .liveATC
    )

    #expect(!segment.requiresVerification)
  }

  @Test func stopCommittedPlaceholderRequiresVerificationEvenWithHighConfidence() {
    let segment = TranscriptSegment(
      text: "Hold short runway two seven",
      confidence: 0.94,
      sourceLanguageCode: "en",
      source: .liveATC,
      isStopCommittedPlaceholder: true
    )

    #expect(segment.requiresVerification)
  }

  @Test func stopCommittedPlaceholderRequiresVerificationAtMaximumConfidence() {
    let segment = TranscriptSegment(
      text: "Maintain runway heading",
      confidence: 1.0,
      sourceLanguageCode: "en",
      source: .liveATC,
      isStopCommittedPlaceholder: true
    )

    #expect(segment.requiresVerification)
  }

  @Test func stopCommittedPlaceholderDefaultsToFalse() {
    let segment = TranscriptSegment(
      text: "Contact tower one one eight decimal seven",
      confidence: 0.90,
      sourceLanguageCode: "en",
      source: .liveATC
    )

    #expect(!segment.isStopCommittedPlaceholder)
  }

  @Test func storedSegmentWithoutPlaceholderFlagDecodesAsRealFinal() throws {
    let fixture = """
      {"confidence":0.86,"id":"00000000-0000-0000-0000-000000000111","source":"replay","sourceLanguageCode":"en","startedAt":42,"text":"Tower, line up and wait"}
      """

    let segment = try JSONDecoder().decode(TranscriptSegment.self, from: Data(fixture.utf8))

    #expect(!segment.isStopCommittedPlaceholder)
  }

  @Test func stopCommittedPlaceholderFlagRoundTrips() throws {
    let segment = TranscriptSegment(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!,
      startedAt: Date(timeIntervalSince1970: 77),
      text: "Climb and maintain five thousand",
      confidence: 0,
      sourceLanguageCode: "en",
      source: .liveATC,
      isStopCommittedPlaceholder: true
    )

    let encoded = try JSONEncoder().encode(segment)
    let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: encoded)

    #expect(decoded == segment)
    #expect(decoded.isStopCommittedPlaceholder)
  }
}
