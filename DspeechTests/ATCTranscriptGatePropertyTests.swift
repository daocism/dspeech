import Foundation
import Testing

@testable import Dspeech

// Property-based tests for the SEGMENT-layer safety gate. These pin the decision cascade's
// guarantees against regression: distress is NEVER hidden, fail-open paths stay open, the pilot is
// suppressed, and a configured callsign is shown exactly when it is addressed (never miss own
// clearance, never show irrelevant traffic). Deterministic seeded PRNG — see PropertyTestSupport.
struct ATCTranscriptGatePropertyTests {

  // Distress is never suppressed: any text carrying an urgency token displays as urgencyBroadcast
  // for EVERY speaker (pilot included), callsign config, and locale — urgency outranks all.
  @Test func urgencyBroadcastAlwaysDisplaysRegardlessOfSpeaker() {
    var rng = SeededGenerator(seed: 0x0A11_0001)
    var exercised = 0
    for _ in 0..<400 {
      let text = injectUrgency(into: randomTranscript(using: &rng), using: &rng)
      let speaker = randomAnySpeaker(using: &rng)
      let callsign =
        Bool.random(using: &rng) ? CallSign(raw: randomCallSignNormalized(using: &rng)) : nil
      let locale = locales.randomElement(using: &rng)!
      var gate = ATCTranscriptGate(configuredCallSign: callsign)
      let decision = gate.evaluate(
        text: text, speaker: speaker, timestamp: t0, localeIdentifier: locale)
      #expect(
        decision == .display(reason: .urgencyBroadcast),
        "urgency must display: '\(text)' speaker=\(speaker)")
      exercised += 1
    }
    #expect(exercised >= 360, "too few cases reached the assertion: \(exercised)")
  }

  // When the recognizer cannot attribute the voice, the gate fails open (display) for any
  // non-urgency text — never gamble a clearance on an unsure speaker call.
  @Test func insufficientSpeechAlwaysDisplays() {
    var rng = SeededGenerator(seed: 0x0A11_0002)
    var exercised = 0
    for _ in 0..<300 {
      let callsign =
        Bool.random(using: &rng) ? CallSign(raw: randomCallSignNormalized(using: &rng)) : nil
      let locale = locales.randomElement(using: &rng)!
      var gate = ATCTranscriptGate(configuredCallSign: callsign)
      let decision = gate.evaluate(
        text: randomTranscript(using: &rng), speaker: .insufficientSpeech, timestamp: t0,
        localeIdentifier: locale)
      #expect(decision == .display(reason: .insufficientSpeech))
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // The crew's own voice is suppressed before any callsign check (voice-first), for any
  // non-urgency text, callsign config, and locale.
  @Test func pilotIsAlwaysSuppressedOnNonUrgencyText() {
    var rng = SeededGenerator(seed: 0x0A11_0003)
    var exercised = 0
    for _ in 0..<300 {
      let callsign =
        Bool.random(using: &rng) ? CallSign(raw: randomCallSignNormalized(using: &rng)) : nil
      let locale = locales.randomElement(using: &rng)!
      var gate = ATCTranscriptGate(configuredCallSign: callsign)
      let decision = gate.evaluate(
        text: randomTranscript(using: &rng), speaker: .pilot(score: randomScore(using: &rng)),
        timestamp: t0, localeIdentifier: locale)
      #expect(decision == .suppress(reason: .pilotReadback))
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // With no callsign anchor, every non-pilot transmission is shown (fail-open) — the app cannot
  // know what is relevant, so it hides nothing.
  @Test func noCallSignConfiguredDisplaysNonPilotTraffic() {
    var rng = SeededGenerator(seed: 0x0A11_0004)
    var exercised = 0
    for _ in 0..<300 {
      let speaker = randomNonPilotOrMixed(using: &rng)
      let locale = locales.randomElement(using: &rng)!
      var gate = ATCTranscriptGate(configuredCallSign: nil)
      let decision = gate.evaluate(
        text: randomTranscript(using: &rng), speaker: speaker, timestamp: t0,
        localeIdentifier: locale)
      #expect(decision == .display(reason: .noCallSignConfigured))
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // For a fresh gate (no prior hit, no other-callsign detector) with a configured callsign and a
  // non-pilot speaker, the decision is TOTAL: show as callSignMatch exactly when the callsign is
  // addressed, otherwise suppress as nonRelevant — and it agrees with CallSign's own matcher.
  @Test func configuredCallSignDisplaysIffAddressedElseSuppresses() {
    var rng = SeededGenerator(seed: 0x0A11_0005)
    var exercised = 0
    for _ in 0..<400 {
      guard let cs = CallSign(raw: randomCallSignNormalized(using: &rng)) else { continue }
      let text: String
      if Bool.random(using: &rng) {
        let lead = noiseWords.randomElement(using: &rng)!
        let trail = noiseWords.randomElement(using: &rng)!
        text = "\(lead) \(cs.normalized) \(trail)"
      } else {
        text = randomTranscript(using: &rng)
      }
      let locale = locales.randomElement(using: &rng)!
      let speaker = randomNonPilotOrMixed(using: &rng)
      var gate = ATCTranscriptGate(configuredCallSign: cs)
      let decision = gate.evaluate(
        text: text, speaker: speaker, timestamp: t0, localeIdentifier: locale)
      let addressed =
        cs.matches(in: text, localeIdentifier: locale)
        || cs.matchesAbbreviated(in: text, localeIdentifier: locale)
      if addressed {
        #expect(
          decision == .display(reason: .callSignMatch),
          "addressed callsign \(cs.normalized) must display: '\(text)'")
      } else {
        #expect(
          decision == .suppress(reason: .nonRelevant),
          "unaddressed callsign \(cs.normalized) must suppress: '\(text)'")
      }
      exercised += 1
    }
    #expect(exercised >= 360, "too few cases reached the assertion: \(exercised)")
  }

  // The gate is a pure value type: two fresh gates with identical config and input return the same
  // decision.
  @Test func evaluationIsDeterministic() {
    var rng = SeededGenerator(seed: 0x0A11_0006)
    var exercised = 0
    for _ in 0..<300 {
      let callsign =
        Bool.random(using: &rng) ? CallSign(raw: randomCallSignNormalized(using: &rng)) : nil
      let urgent = Bool.random(using: &rng)
      let base = randomTranscript(using: &rng)
      let text = urgent ? injectUrgency(into: base, using: &rng) : base
      let speaker = randomAnySpeaker(using: &rng)
      let locale = locales.randomElement(using: &rng)!
      var first = ATCTranscriptGate(configuredCallSign: callsign)
      var second = ATCTranscriptGate(configuredCallSign: callsign)
      let a = first.evaluate(text: text, speaker: speaker, timestamp: t0, localeIdentifier: locale)
      let b = second.evaluate(text: text, speaker: speaker, timestamp: t0, localeIdentifier: locale)
      #expect(a == b)
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // Stateful: after a hit, a following non-matching segment stays visible within the continuation
  // window and is suppressed once it lapses — the gate's only time-dependent branch. A re-addressed
  // follow-up refreshes the hit. (Reviewer-identified coverage gap.)
  @Test func continuationWindowKeepsRecentExchangeVisibleThenLapses() {
    var rng = SeededGenerator(seed: 0x0A11_0007)
    let window = ATCTranscriptGateConfig.default.continuationWindowSeconds
    var exercised = 0
    for _ in 0..<400 {
      guard let cs = CallSign(raw: randomCallSignNormalized(using: &rng)) else { continue }
      let locale = locales.randomElement(using: &rng)!
      var gate = ATCTranscriptGate(configuredCallSign: cs)
      let lead = noiseWords.randomElement(using: &rng)!
      let first = gate.evaluate(
        text: "\(lead) \(cs.normalized)", speaker: randomNonPilotOrMixed(using: &rng),
        timestamp: t0, localeIdentifier: locale)
      #expect(first == .display(reason: .callSignMatch))
      let delta = Double(Int.random(in: 0...16, using: &rng))
      let followText = randomTranscript(using: &rng)
      let second = gate.evaluate(
        text: followText, speaker: randomNonPilotOrMixed(using: &rng),
        timestamp: t0.addingTimeInterval(delta), localeIdentifier: locale)
      let addressed =
        cs.matches(in: followText, localeIdentifier: locale)
        || cs.matchesAbbreviated(in: followText, localeIdentifier: locale)
      if addressed {
        #expect(second == .display(reason: .callSignMatch))
      } else if delta <= window {
        #expect(second == .display(reason: .continuationOfRecentHit))
      } else {
        #expect(second == .suppress(reason: .nonRelevant))
      }
      exercised += 1
    }
    #expect(exercised >= 360, "too few cases reached the assertion: \(exercised)")
  }

  // A non-urgency segment naming a DIFFERENT aircraft (own callsign not matched, other-callsign
  // detector fires) is suppressed as addressedToOther. (Reviewer-identified coverage gap.)
  @Test func otherCallSignDetectorSuppressesForeignTraffic() {
    var rng = SeededGenerator(seed: 0x0A11_0008)
    let marker = "ZZOTHERZZ"
    var exercised = 0
    for _ in 0..<300 {
      guard let cs = CallSign(raw: randomCallSignNormalized(using: &rng)) else { continue }
      let text = "\(noiseWords.randomElement(using: &rng)!) \(marker)"
      guard !cs.matches(in: text, localeIdentifier: nil),
        !cs.matchesAbbreviated(in: text, localeIdentifier: nil)
      else { continue }
      var gate = ATCTranscriptGate(
        configuredCallSign: cs,
        otherCallSignDetector: { @Sendable in $0.contains(marker) })
      let decision = gate.evaluate(
        text: text, speaker: randomNonPilotOrMixed(using: &rng), timestamp: t0,
        localeIdentifier: nil)
      #expect(decision == .suppress(reason: .addressedToOther))
      exercised += 1
    }
    #expect(exercised >= 250, "too few cases reached the assertion: \(exercised)")
  }
}
