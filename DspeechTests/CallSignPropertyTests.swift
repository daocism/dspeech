import Foundation
import Testing

@testable import Dspeech

// Property-based tests for the safety-critical callsign decode/match core. A deterministic seeded
// PRNG drives all generators (testing rule: no real randomness — reproducible counterexamples).
// The invariants pin the two directions that matter: own clearance is NEVER missed (reflexivity in
// every locale) and the locale-aware gate change did NOT alter English behavior.
struct CallSignPropertyTests {

  // MARK: - Properties

  // Own callsign spoken verbatim (compact registration) is detected in EVERY locale — the
  // locale-independent compact-run path must never miss our own clearance.
  @Test func normalizedFormMatchesVerbatimInEveryLocale() {
    var rng = SeededGenerator(seed: 0xA11C_E500)
    var exercised = 0
    for _ in 0..<400 {
      guard let cs = CallSign(raw: randomCallSignNormalized(using: &rng)) else { continue }
      let lead = noiseWords.randomElement(using: &rng)!
      let trail = noiseWords.randomElement(using: &rng)!
      let text = "\(lead) \(cs.normalized) \(trail)"
      for locale in [nil, "en-US", "fr-FR", "de-DE"] as [String?] {
        #expect(
          cs.matches(in: text, localeIdentifier: locale),
          "verbatim \(cs.normalized) must match in locale \(locale ?? "nil") — text: \(text)")
      }
      exercised += 1
    }
    #expect(exercised >= 360, "too few cases reached the assertion: \(exercised)")
  }

  // Own callsign read in ICAO phonetics + English digit words is detected in the English locale.
  @Test func englishPhoneticSpellingMatchesOwnCallsign() {
    var rng = SeededGenerator(seed: 0xCAFE_0011)
    var exercised = 0
    for _ in 0..<400 {
      guard let cs = CallSign(raw: randomCallSignNormalized(using: &rng)) else { continue }
      let spoken = englishSpelling(of: cs.normalized, using: &rng)
      #expect(
        cs.matches(in: spoken, localeIdentifier: "en-US"),
        "english spelling '\(spoken)' must match \(cs.normalized)")
      exercised += 1
    }
    #expect(exercised >= 360, "too few cases reached the assertion: \(exercised)")
  }

  // Own callsign read in ICAO phonetics + FRENCH digit words is detected in the French locale —
  // the capability the locale-aware gate change added.
  @Test func frenchPhoneticSpellingMatchesOwnCallsignInFrenchLocale() {
    var rng = SeededGenerator(seed: 0xF00D_0022)
    var exercised = 0
    for _ in 0..<400 {
      guard let cs = CallSign(raw: randomCallSignNormalized(using: &rng)) else { continue }
      let spoken = frenchSpelling(of: cs.normalized, using: &rng)
      #expect(
        cs.matches(in: spoken, localeIdentifier: "fr-FR"),
        "french spelling '\(spoken)' must match \(cs.normalized) in fr-FR")
      exercised += 1
    }
    #expect(exercised >= 360, "too few cases reached the assertion: \(exercised)")
  }

  // The locale-aware change is behavior-preserving for English: every English spelling of the
  // locale ("en-US", "en", "") and the nil default produce the IDENTICAL match for any text.
  @Test func englishLocaleSpellingsEqualTheDefault() {
    var rng = SeededGenerator(seed: 0xBEEF_0033)
    var exercised = 0
    for _ in 0..<500 {
      guard let cs = CallSign(raw: randomCallSignNormalized(using: &rng)) else { continue }
      let text = randomTranscript(using: &rng)
      let base = cs.matches(in: text)
      let baseAbbreviated = cs.matchesAbbreviated(in: text)
      for locale in ["en-US", "en", ""] {
        #expect(
          cs.matches(in: text, localeIdentifier: locale) == base,
          "english locale '\(locale)' diverged from default for \(cs.normalized) on: \(text)")
        #expect(
          cs.matchesAbbreviated(in: text, localeIdentifier: locale) == baseAbbreviated,
          "abbreviated english locale '\(locale)' diverged for \(cs.normalized) on: \(text)")
      }
      exercised += 1
    }
    #expect(exercised >= 450, "too few cases reached the assertion: \(exercised)")
  }

  // Text with no alphanumeric content never matches in any tier or locale — no spurious own-call.
  @Test func emptyOrPunctuationOnlyNeverMatches() {
    var rng = SeededGenerator(seed: 0x1234_0044)
    let junk = ["", "   ", "\n\t ", "!!! ??? ...", ",,, /// ---", " . , . , "]
    var exercised = 0
    for _ in 0..<300 {
      guard let cs = CallSign(raw: randomCallSignNormalized(using: &rng)) else { continue }
      for text in junk {
        for locale in [nil, "en-US", "fr-FR"] as [String?] {
          #expect(!cs.matches(in: text, localeIdentifier: locale))
          #expect(!cs.matchesAbbreviated(in: text, localeIdentifier: locale))
        }
      }
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // Normalization is idempotent and yields alphanumeric-only uppercase — the form every match
  // path compares against.
  @Test func normalizeIsIdempotentAlphanumericUppercase() {
    var rng = SeededGenerator(seed: 0x5EED_0055)
    for _ in 0..<500 {
      let raw = randomRawString(using: &rng)
      let normalized = CallSign.normalize(raw)
      #expect(CallSign.normalize(normalized) == normalized, "normalize not idempotent on: '\(raw)'")
      #expect(
        normalized.allSatisfy { $0.isLetter || $0.isNumber },
        "non-alphanumeric survived in '\(normalized)' from '\(raw)'")
      #expect(normalized == normalized.uppercased(), "not fully uppercased: '\(normalized)'")
    }
  }

  // Every match tier is a pure function: repeated calls on identical input agree.
  @Test func matchingIsDeterministic() {
    var rng = SeededGenerator(seed: 0xD371_0066)
    let locales: [String?] = [nil, "en-US", "fr-FR", "de-DE"]
    var exercised = 0
    for _ in 0..<400 {
      guard let cs = CallSign(raw: randomCallSignNormalized(using: &rng)) else { continue }
      let text = randomTranscript(using: &rng)
      let locale = locales.randomElement(using: &rng)!
      #expect(
        cs.matches(in: text, localeIdentifier: locale)
          == cs.matches(in: text, localeIdentifier: locale))
      #expect(
        cs.matchesAbbreviated(in: text, localeIdentifier: locale)
          == cs.matchesAbbreviated(in: text, localeIdentifier: locale))
      #expect(
        cs.compacted(in: text, localeIdentifier: locale)
          == cs.compacted(in: text, localeIdentifier: locale))
      exercised += 1
    }
    #expect(exercised >= 360, "too few cases reached the assertion: \(exercised)")
  }
}
