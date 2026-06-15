import Foundation
import Testing

@testable import Dspeech

// Property-based tests for the CARD-layer classifier. Content-first: the configured callsign is
// matched BEFORE voice classification, so a transmission naming our aircraft is shown even from the
// pilot's own voice — the documented divergence from the voice-first segment gate. Pins that
// asymmetry plus the fail-open paths, the voice-majority rule, and the stateful/other-callsign
// branches. Deterministic seeded PRNG — see PropertyTestSupport.
struct TransmissionClassifierPropertyTests {

  // Distress is never filtered: any urgency token displays as urgencyBroadcast for any speakers,
  // callsign config, voice-pack state, and locale.
  @Test func urgencyBroadcastAlwaysDisplays() {
    var rng = SeededGenerator(seed: 0x0C1A_0001)
    var exercised = 0
    for _ in 0..<400 {
      let text = injectUrgency(into: randomTranscript(using: &rng), using: &rng)
      let callsign =
        Bool.random(using: &rng) ? CallSign(raw: randomCallSignNormalized(using: &rng)) : nil
      let locale = locales.randomElement(using: &rng)!
      var classifier = TransmissionClassifier(
        configuredCallSign: callsign, localeIdentifier: locale,
        voicePackActive: Bool.random(using: &rng))
      let result = classifier.classify(
        text: text, speakers: randomSpeakers(using: &rng), endedAt: t0)
      #expect(result == .displayed(.urgencyBroadcast))
      exercised += 1
    }
    #expect(exercised >= 360, "too few cases reached the assertion: \(exercised)")
  }

  // Empty / whitespace-only text is shown as insufficientEvidence — never silently dropped.
  @Test func emptyTextDisplaysAsInsufficientEvidence() {
    var rng = SeededGenerator(seed: 0x0C1A_0002)
    var exercised = 0
    for _ in 0..<200 {
      let callsign =
        Bool.random(using: &rng) ? CallSign(raw: randomCallSignNormalized(using: &rng)) : nil
      let locale = locales.randomElement(using: &rng)!
      for text in ["", "   ", "\n\t "] {
        var classifier = TransmissionClassifier(
          configuredCallSign: callsign, localeIdentifier: locale,
          voicePackActive: Bool.random(using: &rng))
        let result = classifier.classify(
          text: text, speakers: randomSpeakers(using: &rng), endedAt: t0)
        #expect(result == .displayed(.insufficientEvidence))
      }
      exercised += 1
    }
    #expect(exercised >= 180, "too few cases reached the assertion: \(exercised)")
  }

  // THE divergence: a transmission naming our callsign is DISPLAYED even when every speaker is the
  // pilot's own voice — content-first, unlike the voice-first gate which would suppress it.
  @Test func ownCallSignDisplaysEvenFromPilotVoice() {
    var rng = SeededGenerator(seed: 0x0C1A_0003)
    var exercised = 0
    for _ in 0..<400 {
      guard let cs = CallSign(raw: randomCallSignNormalized(using: &rng)) else { continue }
      let lead = noiseWords.randomElement(using: &rng)!
      let text = "\(lead) \(cs.normalized)"
      let locale = locales.randomElement(using: &rng)!
      var classifier = TransmissionClassifier(
        configuredCallSign: cs, localeIdentifier: locale, voicePackActive: true)
      let result = classifier.classify(
        text: text, speakers: allPilotSpeakers(using: &rng), endedAt: t0)
      #expect(
        result == .displayed(.callSignMatch),
        "own callsign \(cs.normalized) must display from pilot voice: '\(text)'")
      exercised += 1
    }
    #expect(exercised >= 360, "too few cases reached the assertion: \(exercised)")
  }

  // With no anchor (no callsign and no voice pack) every non-urgency transmission is shown.
  @Test func noAnchorDisplaysEverything() {
    var rng = SeededGenerator(seed: 0x0C1A_0004)
    var exercised = 0
    for _ in 0..<300 {
      let locale = locales.randomElement(using: &rng)!
      var classifier = TransmissionClassifier(
        configuredCallSign: nil, localeIdentifier: locale, voicePackActive: false)
      let result = classifier.classify(
        text: randomTranscript(using: &rng), speakers: randomSpeakers(using: &rng), endedAt: t0)
      #expect(result == .displayed(.noAnchorConfigured))
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // With a voice pack and no callsign match, a pilot-majority transmission is filtered and a
  // non-pilot-majority one is displayed.
  @Test func voiceMajorityDecidesWhenAnchorUnmatched() {
    var rng = SeededGenerator(seed: 0x0C1A_0005)
    var exercised = 0
    for _ in 0..<300 {
      let locale = locales.randomElement(using: &rng)!
      var pilotHeavy = TransmissionClassifier(
        configuredCallSign: nil, localeIdentifier: locale, voicePackActive: true)
      let pilotResult = pilotHeavy.classify(
        text: randomTranscript(using: &rng), speakers: pilotMajoritySpeakers(using: &rng),
        endedAt: t0)
      #expect(pilotResult == .filtered(.pilotVoice))

      var nonPilotHeavy = TransmissionClassifier(
        configuredCallSign: nil, localeIdentifier: locale, voicePackActive: true)
      let nonPilotResult = nonPilotHeavy.classify(
        text: randomTranscript(using: &rng), speakers: nonPilotMajoritySpeakers(using: &rng),
        endedAt: t0)
      #expect(nonPilotResult == .displayed(.nonPilotVoice))
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // Card-layer (content-first) and segment-gate (voice-first) DIVERGE on the same own-callsign text
  // spoken by the pilot: the classifier displays it, the gate suppresses it. Pins the asymmetry.
  @Test func classifierDisplaysWhereGateSuppressesOwnReadback() {
    var rng = SeededGenerator(seed: 0x0C1A_0006)
    var exercised = 0
    for _ in 0..<400 {
      guard let cs = CallSign(raw: randomCallSignNormalized(using: &rng)) else { continue }
      let lead = noiseWords.randomElement(using: &rng)!
      let text = "\(lead) \(cs.normalized)"
      let locale = locales.randomElement(using: &rng)!
      // confident crew match: the gate suppresses only at/above its suppress threshold.
      let suppress = ATCTranscriptGateConfig.default.pilotSuppressThreshold
      let pilot = SpeakerMatchDecision.pilot(score: Float.random(in: suppress...1, using: &rng))

      var gate = ATCTranscriptGate(configuredCallSign: cs)
      let gated = gate.evaluate(
        text: text, speaker: pilot, timestamp: t0, localeIdentifier: locale)
      #expect(gated == .suppress(reason: .pilotReadback))

      var classifier = TransmissionClassifier(
        configuredCallSign: cs, localeIdentifier: locale, voicePackActive: true)
      let classified = classifier.classify(text: text, speakers: [pilot], endedAt: t0)
      #expect(classified == .displayed(.callSignMatch))
      exercised += 1
    }
    #expect(exercised >= 360, "too few cases reached the assertion: \(exercised)")
  }

  // Stateful: after an anchor, a non-matching follow-up stays visible within the continuation
  // window and is filtered once it lapses (voice pack off so the voice branch doesn't pre-empt it).
  @Test func continuationWindowKeepsRecentCallVisibleThenLapses() {
    var rng = SeededGenerator(seed: 0x0C1A_0007)
    let window = TransmissionClassifierConfig.default.continuationWindowSeconds
    var exercised = 0
    for _ in 0..<400 {
      guard let cs = CallSign(raw: randomCallSignNormalized(using: &rng)) else { continue }
      let locale = locales.randomElement(using: &rng)!
      var classifier = TransmissionClassifier(
        configuredCallSign: cs, localeIdentifier: locale, voicePackActive: false)
      let lead = noiseWords.randomElement(using: &rng)!
      let first = classifier.classify(
        text: "\(lead) \(cs.normalized)", speakers: randomSpeakers(using: &rng), endedAt: t0)
      #expect(first == .displayed(.callSignMatch))
      let delta = Double(Int.random(in: 0...16, using: &rng))
      let followText = randomTranscript(using: &rng)
      let second = classifier.classify(
        text: followText, speakers: randomSpeakers(using: &rng),
        endedAt: t0.addingTimeInterval(delta))
      let addressed =
        cs.matches(in: followText, localeIdentifier: locale)
        || cs.matchesAbbreviated(in: followText, localeIdentifier: locale)
      if addressed {
        #expect(second == .displayed(.callSignMatch))
      } else if delta <= window {
        #expect(second == .displayed(.continuationOfRecentCall))
      } else {
        #expect(second == .filtered(.nonRelevant))
      }
      exercised += 1
    }
    #expect(exercised >= 360, "too few cases reached the assertion: \(exercised)")
  }

  // A non-urgency transmission naming a DIFFERENT aircraft (own callsign unmatched, other-callsign
  // detector fires, voice pack off) is filtered as addressedToOther.
  @Test func otherCallSignDetectorFiltersForeignTraffic() {
    var rng = SeededGenerator(seed: 0x0C1A_0008)
    let marker = "ZZOTHERZZ"
    var exercised = 0
    for _ in 0..<300 {
      guard let cs = CallSign(raw: randomCallSignNormalized(using: &rng)) else { continue }
      let text = "\(noiseWords.randomElement(using: &rng)!) \(marker)"
      guard !cs.matches(in: text, localeIdentifier: nil),
        !cs.matchesAbbreviated(in: text, localeIdentifier: nil)
      else { continue }
      var classifier = TransmissionClassifier(
        configuredCallSign: cs, localeIdentifier: nil, voicePackActive: false,
        otherCallSignDetector: { @Sendable in $0.contains(marker) })
      let result = classifier.classify(
        text: text, speakers: randomSpeakers(using: &rng), endedAt: t0)
      #expect(result == .filtered(.addressedToOther))
      exercised += 1
    }
    #expect(exercised >= 250, "too few cases reached the assertion: \(exercised)")
  }

  // The classifier is a pure value type: two fresh classifiers with identical config and input
  // return the same classification.
  @Test func classificationIsDeterministic() {
    var rng = SeededGenerator(seed: 0x0C1A_0009)
    var exercised = 0
    for _ in 0..<300 {
      let callsign =
        Bool.random(using: &rng) ? CallSign(raw: randomCallSignNormalized(using: &rng)) : nil
      let urgent = Bool.random(using: &rng)
      let base = randomTranscript(using: &rng)
      let text = urgent ? injectUrgency(into: base, using: &rng) : base
      let speakers = randomSpeakers(using: &rng)
      let locale = locales.randomElement(using: &rng)!
      let voicePack = Bool.random(using: &rng)
      var first = TransmissionClassifier(
        configuredCallSign: callsign, localeIdentifier: locale, voicePackActive: voicePack)
      var second = TransmissionClassifier(
        configuredCallSign: callsign, localeIdentifier: locale, voicePackActive: voicePack)
      let a = first.classify(text: text, speakers: speakers, endedAt: t0)
      let b = second.classify(text: text, speakers: speakers, endedAt: t0)
      #expect(a == b)
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }
}

// MARK: - Classifier-specific speaker generators

private func randomSpeakers(using rng: inout SeededGenerator) -> [SpeakerMatchDecision] {
  let count = Int.random(in: 0...5, using: &rng)
  return (0..<count).map { _ in randomAnySpeaker(using: &rng) }
}

private func allPilotSpeakers(using rng: inout SeededGenerator) -> [SpeakerMatchDecision] {
  let count = Int.random(in: 1...4, using: &rng)
  return (0..<count).map { _ in .pilot(score: randomScore(using: &rng)) }
}

// strictly more .pilot than .nonPilot among relevant speakers (no .mixed / .insufficientSpeech),
// so voiceClassification yields a pilot majority.
private func pilotMajoritySpeakers(using rng: inout SeededGenerator) -> [SpeakerMatchDecision] {
  let pilots = Int.random(in: 2...4, using: &rng)
  let others = Int.random(in: 0..<pilots, using: &rng)
  var speakers = (0..<pilots).map { _ in
    SpeakerMatchDecision.pilot(score: randomScore(using: &rng))
  }
  speakers += (0..<others).map { _ in
    SpeakerMatchDecision.nonPilot(bestPilotScore: randomScore(using: &rng))
  }
  return speakers.shuffled(using: &rng)
}

private func nonPilotMajoritySpeakers(using rng: inout SeededGenerator) -> [SpeakerMatchDecision] {
  let nonPilots = Int.random(in: 2...4, using: &rng)
  let others = Int.random(in: 0..<nonPilots, using: &rng)
  var speakers = (0..<nonPilots).map { _ in
    SpeakerMatchDecision.nonPilot(bestPilotScore: randomScore(using: &rng))
  }
  speakers += (0..<others).map { _ in SpeakerMatchDecision.pilot(score: randomScore(using: &rng)) }
  return speakers.shuffled(using: &rng)
}
