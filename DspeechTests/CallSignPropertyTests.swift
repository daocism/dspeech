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

// MARK: - Deterministic generators

// SplitMix64 — a small, deterministic generator so a failing property reproduces from its seed.
private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

private let registrationLetters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

private let noiseWords = [
  "TOWER", "CLEARED", "RUNWAY", "CONTACT", "GROUND", "TAXI", "HOLDING", "WIND", "TRAFFIC",
  "DESCEND", "CLIMB", "APPROACH", "CROSSING", "REPORT",
]

// digit -> spoken-word candidates the recognizer emits (English + ATC transcriber variants).
private let englishDigitWords: [Character: [String]] = [
  "0": ["ZERO"], "1": ["ONE"], "2": ["TWO"], "3": ["THREE", "TREE"],
  "4": ["FOUR", "FOWER"], "5": ["FIVE", "FIFE"], "6": ["SIX"],
  "7": ["SEVEN"], "8": ["EIGHT"], "9": ["NINER", "NINE"],
]

private let frenchDigitWords: [Character: [String]] = [
  "0": ["ZERO"], "1": ["UN", "UNITE"], "2": ["DEUX"], "3": ["TROIS"],
  "4": ["QUATRE"], "5": ["CINQ"], "6": ["SIX"], "7": ["SEPT"],
  "8": ["HUIT"], "9": ["NEUF"],
]

// letters with transcriber spelling variants; others fall back to the ICAO source of truth.
private let letterSpellingVariants: [Character: [String]] = [
  "A": ["ALPHA", "ALFA"], "J": ["JULIETT", "JULIET"], "W": ["WHISKEY", "WHISKY"],
  "X": ["XRAY", "X-RAY"],
]

private func randomCallSignNormalized(using rng: inout SeededGenerator) -> String {
  func letter(_ rng: inout SeededGenerator) -> String {
    String(registrationLetters.randomElement(using: &rng)!)
  }
  func digit(_ rng: inout SeededGenerator) -> String {
    String(Int.random(in: 0...9, using: &rng))
  }
  switch Int.random(in: 0...2, using: &rng) {
  case 0:  // tail-number style: 1 letter + 1...4 digits + 0...3 letters
    var s = letter(&rng)
    for _ in 0..<Int.random(in: 1...4, using: &rng) { s += digit(&rng) }
    for _ in 0..<Int.random(in: 0...3, using: &rng) { s += letter(&rng) }
    return s
  case 1:  // airline style: 2...3 letters + 1...4 digits
    var s = ""
    for _ in 0..<Int.random(in: 2...3, using: &rng) { s += letter(&rng) }
    for _ in 0..<Int.random(in: 1...4, using: &rng) { s += digit(&rng) }
    return s
  default:  // mixed alphanumeric run
    var s = ""
    for _ in 0..<Int.random(in: 3...6, using: &rng) {
      s += Bool.random(using: &rng) ? letter(&rng) : digit(&rng)
    }
    return s
  }
}

private func spelling(
  of normalized: String,
  digitWords: [Character: [String]],
  using rng: inout SeededGenerator
) -> String {
  normalized.map { character -> String in
    if character.isNumber { return digitWords[character]!.randomElement(using: &rng)! }
    if let variants = letterSpellingVariants[character] {
      return variants.randomElement(using: &rng)!
    }
    return PhoneticAlphabet.icao[character]!
  }.joined(separator: " ")
}

private func englishSpelling(of normalized: String, using rng: inout SeededGenerator) -> String {
  spelling(of: normalized, digitWords: englishDigitWords, using: &rng)
}

private func frenchSpelling(of normalized: String, using rng: inout SeededGenerator) -> String {
  spelling(of: normalized, digitWords: frenchDigitWords, using: &rng)
}

private func randomTranscript(using rng: inout SeededGenerator) -> String {
  let pool =
    noiseWords
    + PhoneticAlphabet.icao.values.sorted()
    + [
      "ONE", "TWO", "THREE", "NINER", "NINE", "TREE", "UN", "DEUX", "TROIS", "NEUF", "SEPT",
      "HUIT", "DECIMALE", "VIRGULE",
    ]
    + ["123", "27", "0", "9", "2", "700"]
  let separators = [" ", "  ", ", ", "-", "/", " . "]
  let count = Int.random(in: 0...12, using: &rng)
  var parts: [String] = []
  for _ in 0..<count { parts.append(pool.randomElement(using: &rng)!) }
  var text = ""
  for (index, part) in parts.enumerated() {
    text += part
    if index < parts.count - 1 { text += separators.randomElement(using: &rng)! }
  }
  return text
}

private func randomRawString(using rng: inout SeededGenerator) -> String {
  // letters (mixed case), digits, separators the normalizer cares about, and accented Latin that
  // uppercases cleanly — exercising the strip/uppercase path without exotic Unicode edge cases.
  let alphabet = Array("abcdefghijABCDEFGHIJ0123456789 -/.,!?()éüñ")
  let count = Int.random(in: 0...18, using: &rng)
  var s = ""
  for _ in 0..<count { s.append(alphabet.randomElement(using: &rng)!) }
  return s
}
