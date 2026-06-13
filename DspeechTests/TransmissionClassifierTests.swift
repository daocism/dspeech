import Foundation
import Testing

@testable import Dspeech

struct TransmissionClassifierTests {
  @Test func emptyTextDisplaysInsufficientEvidence() {
    var classifier = TransmissionClassifier(
      configuredCallSign: CallSign(raw: "N123AB"),
      localeIdentifier: nil,
      voicePackActive: true
    )

    let classification = classifier.classify(
      text: "  \n\t  ",
      speakers: [.pilot(slot: .primary, score: 0.99)],
      endedAt: Self.t(0)
    )

    #expect(classification == .displayed(.insufficientEvidence))
  }

  @Test func urgencyPhraseDisplaysAndRefreshesContinuationAnchor() {
    var classifier = TransmissionClassifier(
      configuredCallSign: CallSign(raw: "N123AB"),
      localeIdentifier: nil,
      voicePackActive: true
    )

    let first = classifier.classify(
      text: "PAN PAN engine failure",
      speakers: [.pilot(slot: .primary, score: 0.99)],
      endedAt: Self.t(0)
    )
    let continuation = classifier.classify(
      text: "turn left heading two seven zero",
      speakers: [.mixed(bestPilotScore: 0.50)],
      endedAt: Self.t(6)
    )

    #expect(first == .displayed(.urgencyBroadcast))
    #expect(continuation == .displayed(.continuationOfRecentCall))
  }

  @Test func ownCallSignDisplaysAndRefreshesContinuationAnchor() {
    var classifier = TransmissionClassifier(
      configuredCallSign: CallSign(raw: "N123AB"),
      localeIdentifier: nil,
      voicePackActive: false
    )

    let first = classifier.classify(
      text: "November One Two Three Alpha Bravo, climb flight level one eight zero",
      speakers: [],
      endedAt: Self.t(0)
    )
    let continuation = classifier.classify(
      text: "contact departure one two four decimal five",
      speakers: [],
      endedAt: Self.t(7)
    )

    #expect(first == .displayed(.callSignMatch))
    #expect(continuation == .displayed(.continuationOfRecentCall))
  }

  @Test func majorityPilotVoiceFiltersWhenVoicePackIsActive() {
    var classifier = TransmissionClassifier(
      configuredCallSign: CallSign(raw: "N123AB"),
      localeIdentifier: nil,
      voicePackActive: true
    )

    let classification = classifier.classify(
      text: "roger we are climbing",
      speakers: [
        .pilot(slot: .primary, score: 0.91),
        .pilot(slot: .primary, score: 0.88),
        .nonPilot(bestPilotScore: 0.12),
        .insufficientSpeech,
      ],
      endedAt: Self.t(0)
    )

    #expect(classification == .filtered(.pilotVoice))
  }

  @Test func majorityNonPilotVoiceDisplaysWhenVoicePackIsActive() {
    var classifier = TransmissionClassifier(
      configuredCallSign: CallSign(raw: "N123AB"),
      localeIdentifier: nil,
      voicePackActive: true
    )

    let classification = classifier.classify(
      text: "turn right heading two one zero",
      speakers: [
        .nonPilot(bestPilotScore: 0.18),
        .mixed(bestPilotScore: 0.51),
        .nonPilot(bestPilotScore: 0.21),
      ],
      endedAt: Self.t(0)
    )

    #expect(classification == .displayed(.nonPilotVoice))
  }

  @Test func noCallSignAndNoVoicePackDisplaysHonestFallbackBeforeOtherCallSignDetector() {
    var classifier = TransmissionClassifier(
      configuredCallSign: nil,
      localeIdentifier: nil,
      voicePackActive: false,
      otherCallSignDetector: { _ in true }
    )

    let classification = classifier.classify(
      text: "Speedbird 247 contact tower",
      speakers: [.pilot(slot: .primary, score: 0.99)],
      endedAt: Self.t(0)
    )

    #expect(classification == .displayed(.noAnchorConfigured))
  }

  @Test func addressedToOtherFiltersAfterOwnAnchorsAreAbsent() {
    var classifier = TransmissionClassifier(
      configuredCallSign: CallSign(raw: "N123AB"),
      localeIdentifier: nil,
      voicePackActive: false,
      otherCallSignDetector: { text in text.contains("Speedbird") }
    )

    let classification = classifier.classify(
      text: "Speedbird 247 contact tower",
      speakers: [],
      endedAt: Self.t(0)
    )

    #expect(classification == .filtered(.addressedToOther))
  }

  @Test func continuationDoesNotRefreshItsOwnAnchor() {
    var classifier = TransmissionClassifier(
      config: TransmissionClassifierConfig(continuationWindowSeconds: 8),
      configuredCallSign: CallSign(raw: "N123AB"),
      localeIdentifier: nil,
      voicePackActive: false
    )

    let anchor = classifier.classify(
      text: "November One Two Three Alpha Bravo, descend four thousand",
      speakers: [],
      endedAt: Self.t(0)
    )
    let firstContinuation = classifier.classify(
      text: "reduce speed two one zero knots",
      speakers: [],
      endedAt: Self.t(6)
    )
    let secondContinuation = classifier.classify(
      text: "turn left heading two four zero",
      speakers: [],
      endedAt: Self.t(10)
    )

    #expect(anchor == .displayed(.callSignMatch))
    #expect(firstContinuation == .displayed(.continuationOfRecentCall))
    #expect(secondContinuation == .filtered(.nonRelevant))
  }

  @Test func urgencyBeatsPilotVoice() {
    var classifier = TransmissionClassifier(
      configuredCallSign: CallSign(raw: "N123AB"),
      localeIdentifier: nil,
      voicePackActive: true
    )

    let classification = classifier.classify(
      text: "MAYDAY MAYDAY loss of engine",
      speakers: [.pilot(slot: .primary, score: 0.99)],
      endedAt: Self.t(0)
    )

    #expect(classification == .displayed(.urgencyBroadcast))
  }

  @Test func ownCallSignBeatsAddressedToOtherDetector() {
    var classifier = TransmissionClassifier(
      configuredCallSign: CallSign(raw: "N123AB"),
      localeIdentifier: nil,
      voicePackActive: false,
      otherCallSignDetector: { _ in true }
    )

    let classification = classifier.classify(
      text: "November One Two Three Alpha Bravo, cleared to land",
      speakers: [],
      endedAt: Self.t(0)
    )

    #expect(classification == .displayed(.callSignMatch))
  }

  @Test func frenchCallSignAnchorsWhenLocaleIsFrench() {
    var classifier = TransmissionClassifier(
      configuredCallSign: CallSign(raw: "FGO78"),
      localeIdentifier: "fr-FR",
      voicePackActive: false
    )

    let classification = classifier.classify(
      text: "Tour, Foxtrot Golf Oscar sept huit, autorisé atterrissage piste deux six",
      speakers: [],
      endedAt: Self.t(0)
    )

    #expect(classification == .displayed(.callSignMatch))
  }

  private static func t(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
  }
}
