import Foundation
import Testing

@testable import Dspeech

// Characterization lock for the two-layer ATC-relevance design. The SEGMENT gate
// (ATCTranscriptGate, one speaker -> suppress/show a segment) and the CARD classifier
// (TransmissionClassifier, many speakers -> displayed/filtered card) intentionally diverge on
// ONE scenario: a pilot reading back their OWN callsign. The gate suppresses it (voice-first
// noise filtering — don't echo the crew's own voice); the classifier displays it (content-first
// relevance — a transmission naming your aircraft is shown). These tests pin that asymmetry so
// neither engine's decision ORDER can drift silently. Any future consolidation must preserve
// both behaviors, or change them through an explicit product decision (ADR). See the header
// docs on ATCTranscriptGate and TransmissionClassifier.
struct VoiceFilterDivergenceTests {
  private static func t(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
  private static let ownCallSign = CallSign(raw: "N123AB")
  // Phonetic so the callsign matcher fires for the classifier; the gate suppresses any pilot
  // regardless of text, so the same input exercises both layers.
  private static let pilotReadback = "November One Two Three Alpha Bravo descending two thousand"

  @Test func gateSuppressesPilotReadbackOfOwnCallSign() {
    var gate = ATCTranscriptGate(configuredCallSign: Self.ownCallSign)
    let decision = gate.evaluate(
      text: Self.pilotReadback,
      speaker: .pilot(score: 0.91),
      timestamp: Self.t(0)
    )
    #expect(decision == .suppress(reason: .pilotReadback))
  }

  @Test func classifierDisplaysOwnCallSignDespitePilotSpeakers() {
    var classifier = TransmissionClassifier(
      configuredCallSign: Self.ownCallSign,
      localeIdentifier: nil,
      voicePackActive: true
    )
    let decision = classifier.classify(
      text: Self.pilotReadback,
      speakers: [.pilot(score: 0.91), .pilot(score: 0.88)],
      endedAt: Self.t(0)
    )
    #expect(decision == .displayed(.callSignMatch))
  }

  // The asymmetry as one fact: identical text + pilot voice, opposite visibility per layer.
  @Test func pilotReadbackOfOwnCallSignIsAsymmetricAcrossLayers() {
    var gate = ATCTranscriptGate(configuredCallSign: Self.ownCallSign)
    var classifier = TransmissionClassifier(
      configuredCallSign: Self.ownCallSign,
      localeIdentifier: nil,
      voicePackActive: true
    )
    let segment = gate.evaluate(
      text: Self.pilotReadback, speaker: .pilot(score: 0.9), timestamp: Self.t(0))
    let card = classifier.classify(
      text: Self.pilotReadback, speakers: [.pilot(score: 0.9)], endedAt: Self.t(0))

    #expect(segment == .suppress(reason: .pilotReadback))
    #expect(card == .displayed(.callSignMatch))
  }

  // Where they MUST agree: an urgency broadcast is always shown by both layers, ahead of any
  // speaker or callsign logic.
  @Test func urgencyBroadcastDisplaysInBothLayers() {
    var gate = ATCTranscriptGate(configuredCallSign: Self.ownCallSign)
    var classifier = TransmissionClassifier(
      configuredCallSign: Self.ownCallSign,
      localeIdentifier: nil,
      voicePackActive: true
    )
    let mayday = "Mayday Mayday Mayday November One Two Three Alpha Bravo engine failure"
    let segment = gate.evaluate(text: mayday, speaker: .pilot(score: 0.9), timestamp: Self.t(0))
    let card = classifier.classify(
      text: mayday, speakers: [.pilot(score: 0.9)], endedAt: Self.t(0))

    #expect(segment == .display(reason: .urgencyBroadcast))
    #expect(card == .displayed(.urgencyBroadcast))
  }

  // The divergence is specifically callsign-gated, not a blanket "classifier ignores voice":
  // with no callsign in the text, the classifier still filters majority-pilot voice.
  @Test func classifierFiltersMajorityPilotWhenNoCallSignInText() {
    var classifier = TransmissionClassifier(
      configuredCallSign: Self.ownCallSign,
      localeIdentifier: nil,
      voicePackActive: true
    )
    let decision = classifier.classify(
      text: "descending two thousand",
      speakers: [.pilot(score: 0.9), .pilot(score: 0.88)],
      endedAt: Self.t(0)
    )
    #expect(decision == .filtered(.pilotVoice))
  }
}
