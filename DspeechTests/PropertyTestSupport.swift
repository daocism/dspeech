import Foundation

@testable import Dspeech

// Shared deterministic generators for the voice-filter property tests. A seeded PRNG keeps every
// property reproducible (testing rule: no real randomness — a failure repeats from its seed), with
// stable ordering everywhere (no unsorted Dictionary iteration) so counterexamples reproduce.

// SplitMix64 — small, deterministic, good distribution.
struct SeededGenerator: RandomNumberGenerator {
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

let registrationLetters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

// Common non-phonetic ATC filler words — none decode to a callsign character.
let noiseWords = [
  "TOWER", "CLEARED", "RUNWAY", "CONTACT", "GROUND", "TAXI", "HOLDING", "WIND", "TRAFFIC",
  "DESCEND", "CLIMB", "APPROACH", "CROSSING", "REPORT",
]

// digit -> spoken-word candidates the recognizer emits (English + ATC transcriber variants).
let englishDigitWords: [Character: [String]] = [
  "0": ["ZERO"], "1": ["ONE"], "2": ["TWO"], "3": ["THREE", "TREE"],
  "4": ["FOUR", "FOWER"], "5": ["FIVE", "FIFE"], "6": ["SIX"],
  "7": ["SEVEN"], "8": ["EIGHT"], "9": ["NINER", "NINE"],
]

let frenchDigitWords: [Character: [String]] = [
  "0": ["ZERO"], "1": ["UN", "UNITE"], "2": ["DEUX"], "3": ["TROIS"],
  "4": ["QUATRE"], "5": ["CINQ"], "6": ["SIX"], "7": ["SEPT"],
  "8": ["HUIT"], "9": ["NEUF"],
]

// letters with transcriber spelling variants; others fall back to the ICAO source of truth.
let letterSpellingVariants: [Character: [String]] = [
  "A": ["ALPHA", "ALFA"], "J": ["JULIETT", "JULIET"], "W": ["WHISKEY", "WHISKY"],
  "X": ["XRAY", "X-RAY"],
]

func randomCallSignNormalized(using rng: inout SeededGenerator) -> String {
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

func spelling(
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

func englishSpelling(of normalized: String, using rng: inout SeededGenerator) -> String {
  spelling(of: normalized, digitWords: englishDigitWords, using: &rng)
}

func frenchSpelling(of normalized: String, using rng: inout SeededGenerator) -> String {
  spelling(of: normalized, digitWords: frenchDigitWords, using: &rng)
}

// Arbitrary messy ATC-like text — always non-empty (a transmission has content; the empty case is
// its own concern) and containing NO urgency tokens (MAYDAY/PAN PAN/SECURITE/ALL STATIONS), so
// callers can treat it as non-urgency, non-empty input.
func randomTranscript(using rng: inout SeededGenerator) -> String {
  let pool =
    noiseWords
    + PhoneticAlphabet.icao.values.sorted()
    + [
      "ONE", "TWO", "THREE", "NINER", "NINE", "TREE", "UN", "DEUX", "TROIS", "NEUF", "SEPT",
      "HUIT", "DECIMALE", "VIRGULE",
    ]
    + ["123", "27", "0", "9", "2", "700"]
  let separators = [" ", "  ", ", ", "-", "/", " . "]
  let count = Int.random(in: 1...12, using: &rng)
  var parts: [String] = []
  for _ in 0..<count { parts.append(pool.randomElement(using: &rng)!) }
  var text = ""
  for (index, part) in parts.enumerated() {
    text += part
    if index < parts.count - 1 { text += separators.randomElement(using: &rng)! }
  }
  return text
}

func randomRawString(using rng: inout SeededGenerator) -> String {
  // letters (mixed case), digits, separators the normalizer cares about, and accented Latin that
  // uppercases cleanly — exercising the strip/uppercase path without exotic Unicode edge cases.
  let alphabet = Array("abcdefghijABCDEFGHIJ0123456789 -/.,!?()éüñ")
  let count = Int.random(in: 0...18, using: &rng)
  var s = ""
  for _ in 0..<count { s.append(alphabet.randomElement(using: &rng)!) }
  return s
}

// MARK: - Gate / classifier shared generators

// A fixed reference timestamp + locale set for the gate and classifier suites.
let t0 = Date(timeIntervalSinceReferenceDate: 0)
let locales: [String?] = [nil, "en-US", "fr-FR"]

let urgencyPhrases = [
  "MAYDAY", "PAN PAN", "PANPAN", "SECURITE", "SÉCURITÉ", "ALL STATIONS",
]

func randomScore(using rng: inout SeededGenerator) -> Float {
  Float(Int.random(in: 0...1000, using: &rng)) / 1000
}

func randomNonPilotOrMixed(using rng: inout SeededGenerator) -> SpeakerMatchDecision {
  Bool.random(using: &rng)
    ? .nonPilot(bestPilotScore: randomScore(using: &rng))
    : .mixed(bestPilotScore: randomScore(using: &rng))
}

func randomAnySpeaker(using rng: inout SeededGenerator) -> SpeakerMatchDecision {
  switch Int.random(in: 0...3, using: &rng) {
  case 0: return .pilot(score: randomScore(using: &rng))
  case 1: return .nonPilot(bestPilotScore: randomScore(using: &rng))
  case 2: return .mixed(bestPilotScore: randomScore(using: &rng))
  default: return .insufficientSpeech
  }
}

func injectUrgency(into text: String, using rng: inout SeededGenerator) -> String {
  let phrase = urgencyPhrases.randomElement(using: &rng)!
  switch Int.random(in: 0...2, using: &rng) {
  case 0: return "\(phrase) \(text)"
  case 1: return "\(text) \(phrase)"
  default:
    let words = text.split(separator: " ")
    guard words.count > 1 else { return "\(phrase) \(text)" }
    let mid = words.count / 2
    let head = words[..<mid].joined(separator: " ")
    let tail = words[mid...].joined(separator: " ")
    return "\(head) \(phrase) \(tail)"
  }
}
