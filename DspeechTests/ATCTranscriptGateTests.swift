import AVFoundation
import CryptoKit
import FluidAudio
import Foundation
import Testing

@testable import Dspeech

struct ATCTranscriptGateTests {
  private let t0 = Date(timeIntervalSince1970: 0)

  @Test func noCallSignDisplaysAllNonPilotSegments() {
    var gate = ATCTranscriptGate()
    let dec = gate.evaluate(
      text: "United 247 contact ground point niner",
      speaker: .nonPilot(bestPilotScore: 0.1),
      timestamp: t0
    )
    #expect(dec == .display(reason: .noCallSignConfigured))
  }

  @Test func pilotReadbackContainingCallSignIsSuppressed() {
    var gate = ATCTranscriptGate(configuredCallSign: CallSign(raw: "N123AB"))
    let dec = gate.evaluate(
      text: "N123AB descending two thousand",
      speaker: .pilot(score: 0.91),
      timestamp: t0
    )
    #expect(dec == .suppress(reason: .pilotReadback))
  }

  // why: a numeric tail (N12345) — so ONLY the French digit decode can match it; a letter tail like
  // "AB" would match via the lenient abbreviation tier even in English, masking the locale effect.
  @Test func gateMatchesOwnCallSignInFrenchLocale() {
    var gate = ATCTranscriptGate(configuredCallSign: CallSign(raw: "N12345"))
    let dec = gate.evaluate(
      text: "November un deux trois quatre cinq, autorisé à atterrir",
      speaker: .nonPilot(bestPilotScore: 0.1),
      timestamp: t0,
      localeIdentifier: "fr-FR"
    )
    #expect(dec == .display(reason: .callSignMatch))
  }

  // Regression guard for the fix: without the French locale the French digit words don't decode, so
  // the gate does NOT match our own callsign — the bug that wrongly suppressed French clearances.
  @Test func gateDoesNotMatchFrenchDigitsWithoutFrenchLocale() {
    var gate = ATCTranscriptGate(configuredCallSign: CallSign(raw: "N12345"))
    let dec = gate.evaluate(
      text: "November un deux trois quatre cinq, autorisé à atterrir",
      speaker: .nonPilot(bestPilotScore: 0.1),
      timestamp: t0,
      localeIdentifier: "en-US"
    )
    #expect(dec != .display(reason: .callSignMatch))
  }

  @Test func nonPilotWithCallSignMatchDisplays() {
    var gate = ATCTranscriptGate(configuredCallSign: CallSign(raw: "N123AB"))
    let dec = gate.evaluate(
      text: "N123AB descend and maintain three thousand",
      speaker: .nonPilot(bestPilotScore: 0.05),
      timestamp: t0
    )
    #expect(dec == .display(reason: .callSignMatch))
  }

  @Test(arguments: [
    "November Three Alpha Bravo",
    "Three Alpha Bravo",
    "N3AB",
    "Two Three Alpha Bravo",
    "Cessna Three Alpha Bravo",
  ])
  func nonPilotWithAbbreviatedCallSignMatchDisplays(_ transcript: String) {
    var gate = ATCTranscriptGate(configuredCallSign: CallSign(raw: "N123AB"))
    let dec = gate.evaluate(
      text: transcript,
      speaker: .nonPilot(bestPilotScore: 0.05),
      timestamp: t0
    )
    #expect(dec == .display(reason: .callSignMatch))
  }

  @Test func continuationWithinWindowDisplays() {
    var gate = ATCTranscriptGate(configuredCallSign: CallSign(raw: "N123AB"))
    _ = gate.evaluate(
      text: "N123AB contact tower one one eight decimal three",
      speaker: .nonPilot(bestPilotScore: 0.05),
      timestamp: t0
    )
    let cont = gate.evaluate(
      text: "expedite if able",
      speaker: .nonPilot(bestPilotScore: 0.05),
      timestamp: t0.addingTimeInterval(3)
    )
    #expect(cont == .display(reason: .continuationOfRecentHit))
  }

  @Test func displayedContinuationRefreshesRelevanceWindow() {
    var gate = ATCTranscriptGate(
      config: ATCTranscriptGateConfig(
        continuationWindowSeconds: 5, readbackMaxWords: 16, pilotSuppressThreshold: 0.82),
      configuredCallSign: CallSign(raw: "N123AB")
    )
    let first = gate.evaluate(
      text: "N123AB contact tower one one eight decimal three",
      speaker: .nonPilot(bestPilotScore: 0.05),
      timestamp: t0
    )
    let second = gate.evaluate(
      text: "continue approach",
      speaker: .nonPilot(bestPilotScore: 0.05),
      timestamp: t0.addingTimeInterval(4)
    )
    let third = gate.evaluate(
      text: "turn base now",
      speaker: .nonPilot(bestPilotScore: 0.05),
      timestamp: t0.addingTimeInterval(8)
    )
    #expect(first == .display(reason: .callSignMatch))
    #expect(second == .display(reason: .continuationOfRecentHit))
    #expect(third == .display(reason: .continuationOfRecentHit))
  }

  @Test func nonPilotWithoutCallSignAndExpiredWindowSuppresses() {
    var gate = ATCTranscriptGate(configuredCallSign: CallSign(raw: "N123AB"))
    let dec = gate.evaluate(
      text: "United 247 turn right heading two seven zero",
      speaker: .nonPilot(bestPilotScore: 0.05),
      timestamp: t0
    )
    #expect(dec == .suppress(reason: .nonRelevant))
  }

  @Test func addressedToOtherDetectorSuppresses() {
    let detector: @Sendable (String) -> Bool = { $0.uppercased().contains("UNITED 247") }
    var gate = ATCTranscriptGate(
      configuredCallSign: CallSign(raw: "N123AB"),
      otherCallSignDetector: detector
    )
    let dec = gate.evaluate(
      text: "United 247 cleared visual approach",
      speaker: .nonPilot(bestPilotScore: 0.05),
      timestamp: t0
    )
    #expect(dec == .suppress(reason: .addressedToOther))
  }

  @Test func insufficientSpeechDisplaysFailOpen() {
    var gate = ATCTranscriptGate(configuredCallSign: CallSign(raw: "N123AB"))
    let dec = gate.evaluate(text: "anything", speaker: .insufficientSpeech, timestamp: t0)
    #expect(dec == .display(reason: .insufficientSpeech))
  }

  @Test(arguments: [
    (
      "MAYDAY MAYDAY MAYDAY immediate descent",
      SpeakerMatchDecision.pilot(score: 0.99)
    ),
    ("PAN PAN PAN PAN PAN PAN engine failure", SpeakerMatchDecision.insufficientSpeech),
    ("pan-pan fuel emergency", SpeakerMatchDecision.nonPilot(bestPilotScore: 0.01)),
    ("PANPAN medical priority", SpeakerMatchDecision.mixed(bestPilotScore: 0.61)),
    ("Sécurité traffic advisory", SpeakerMatchDecision.nonPilot(bestPilotScore: 0.01)),
    ("All stations, stop transmitting", SpeakerMatchDecision.insufficientSpeech),
  ])
  func urgencyBroadcastAlwaysDisplaysAboveEveryOtherGate(
    _ sample: (text: String, speaker: SpeakerMatchDecision)
  ) {
    let detector: @Sendable (String) -> Bool = { _ in true }
    var gate = ATCTranscriptGate(
      config: ATCTranscriptGateConfig(
        continuationWindowSeconds: 0, readbackMaxWords: 1, pilotSuppressThreshold: 0.82),
      configuredCallSign: CallSign(raw: "N123AB"),
      otherCallSignDetector: detector
    )
    let dec = gate.evaluate(text: sample.text, speaker: sample.speaker, timestamp: t0)
    #expect(dec == .display(reason: .urgencyBroadcast))
  }

  @Test func singlePanProseIsNotUrgencyBroadcast() {
    var gate = ATCTranscriptGate(configuredCallSign: CallSign(raw: "N123AB"))
    let dec = gate.evaluate(
      text: "company pan schedule is delayed",
      speaker: .nonPilot(bestPilotScore: 0.01),
      timestamp: t0
    )
    #expect(dec == .suppress(reason: .nonRelevant))
  }
}
