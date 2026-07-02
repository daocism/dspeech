import Foundation
import Testing

@testable import Dspeech

// Property-based tests for the ENROLLMENT phonetic parser `PhoneticCallsignParser.parse`. A
// deterministic seeded PRNG (SeededGenerator from PropertyTestSupport) drives every generator so a
// failure reproduces from its seed. Properties enumerate each branch of the parser: the English vs
// French (foldDiacritics) token path, the x/ex + "ray" merge, ICAO-letter and English-digit-word
// decoding, the spoken digit HOMOPHONES this parser tolerates (won/too/to/for/fore/ate/...), the
// French digit words under fr-FR + the ignored decimal fillers, the context-sensitive "oh"->0 rule,
// the unknown-word alphanumeric passthrough, and the empty/garbage cases. This is the enrollment
// parser — distinct from CallSign transcript MATCHING — so it round-trips a spelling back to the
// compact uppercase callsign rather than locating one inside noisy text.

// MARK: - Component-specific generators (file-scope, private)

// ICAO letter -> the spoken word variants this parser decodes back to that letter. Mirrors the
// SUT's tokenMap (the proven source of truth), including the transcriber spelling variants.
private let letterSpokenVariants: [Character: [String]] = [
  "A": ["alpha", "alfa"], "B": ["bravo"], "C": ["charlie"], "D": ["delta"],
  "E": ["echo"], "F": ["foxtrot", "fox"], "G": ["golf"], "H": ["hotel"],
  "I": ["india"], "J": ["juliett", "juliet"], "K": ["kilo"], "L": ["lima"],
  "M": ["mike"], "N": ["november"], "O": ["oscar"], "P": ["papa"],
  "Q": ["quebec"], "R": ["romeo"], "S": ["sierra"], "T": ["tango"],
  "U": ["uniform"], "V": ["victor"], "W": ["whiskey", "whisky"],
  "X": ["xray", "x-ray", "ex-ray", "x ray"], "Y": ["yankee"], "Z": ["zulu"],
]

// English digit -> spoken-word variants the SUT decodes, INCLUDING the homophones this parser
// tolerates: won/too/to/tree/for/fore/fower/fife/ate/niner.
private let englishDigitSpokenVariants: [Character: [String]] = [
  "0": ["zero"], "1": ["one", "won"], "2": ["two", "too", "to"],
  "3": ["three", "tree"], "4": ["four", "fower", "for", "fore"],
  "5": ["five", "fife"], "6": ["six"], "7": ["seven"],
  "8": ["eight", "ate"], "9": ["nine", "niner"],
]

// French digit -> spoken-word variants decoded only under a French locale. UNITE folded to "unite".
private let frenchDigitSpokenVariants: [Character: [String]] = [
  "0": ["zero", "zéro"], "1": ["un", "unité"], "2": ["deux"], "3": ["trois"],
  "4": ["quatre"], "5": ["cinq"], "6": ["six"], "7": ["sept"],
  "8": ["huit"], "9": ["neuf"],
]

private let callsignLetters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
private let callsignDigits = Array("0123456789")

// A compact callsign-shaped string: a letter, then a mix of 1...6 letters/digits. Always begins
// with a letter so the leading token is never an ambiguous bare digit. Result is A-Z0-9 only.
private func randomCallsign(using rng: inout SeededGenerator) -> String {
  var s = String(callsignLetters.randomElement(using: &rng)!)
  let tail = Int.random(in: 1...6, using: &rng)
  for _ in 0..<tail {
    s.append(
      Bool.random(using: &rng)
        ? callsignLetters.randomElement(using: &rng)!
        : callsignDigits.randomElement(using: &rng)!)
  }
  return s
}

// Spell a compact callsign with the given letter/digit spoken-variant tables, space-joined.
private func spell(
  _ normalized: String,
  letters: [Character: [String]],
  digits: [Character: [String]],
  using rng: inout SeededGenerator
) -> String {
  normalized.map { ch -> String in
    if ch.isNumber { return digits[ch]!.randomElement(using: &rng)! }
    return letters[ch]!.randomElement(using: &rng)!
  }.joined(separator: " ")
}

private func englishSpell(_ s: String, using rng: inout SeededGenerator) -> String {
  spell(s, letters: letterSpokenVariants, digits: englishDigitSpokenVariants, using: &rng)
}

private func frenchSpell(_ s: String, using rng: inout SeededGenerator) -> String {
  spell(s, letters: letterSpokenVariants, digits: frenchDigitSpokenVariants, using: &rng)
}

// Separator-only / empty garbage: characters the parser strips entirely (non-alphanumerics) plus
// whitespace. Contains no alphanumeric content, so the parse must be empty.
private let separatorCharacters = Array(" \n\t.,;:!?-_/()[]{}\"'@#%&*+=<>|\\~`")

private func separatorGarbage(using rng: inout SeededGenerator) -> String {
  let count = Int.random(in: 0...48, using: &rng)
  var s = ""
  for _ in 0..<count { s.append(separatorCharacters.randomElement(using: &rng)!) }
  return s
}

// A free-form messy ASCII string mixing known spoken words, unknown words, digits, and separators —
// for invariants that must hold on ARBITRARY input (idempotence, uppercase, alnum-only).
// why: Dictionary.values iteration order is randomized PER PROCESS, so pools built from it
// silently defeat the seeded PRNG — the same seed would generate different inputs per launch.
// Sorted pools make the seed actually reproduce.
private let arbitraryWordPool: [String] =
  Array(letterSpokenVariants.values.joined()).sorted()
  + Array(englishDigitSpokenVariants.values.joined()).sorted()
  + ["lufthansa", "speedbird", "oh", "say", "heavy", "n123ab", "27r", "xyz", "qqq", "x", "ex"]
  + ["ray"]

private func arbitraryText(using rng: inout SeededGenerator) -> String {
  let count = Int.random(in: 0...10, using: &rng)
  var parts: [String] = []
  for _ in 0..<count {
    if Bool.random(using: &rng) {
      parts.append(arbitraryWordPool.randomElement(using: &rng)!)
    } else {
      parts.append(separatorGarbage(using: &rng))
    }
  }
  let separators = [" ", "  ", "-", ".", ", ", " . ", "/"]
  return parts.joined(separator: separators.randomElement(using: &rng)!)
}

private let knownEnglishTokens: [String] =
  Array(letterSpokenVariants.values.joined()).sorted()
  + Array(englishDigitSpokenVariants.values.joined()).sorted()

private func isAlphanumericUppercase(_ s: String) -> Bool {
  s.unicodeScalars.allSatisfy {
    CharacterSet.alphanumerics.contains($0) && !CharacterSet.lowercaseLetters.contains($0)
  }
}

// MARK: - Suite

struct PhoneticCallsignParserPropertyTests {

  // English spelling (B2 lowercased path, B9 tokenMap hit, B16/B17 context, B18 append, B20 upper)
  // of a compact callsign round-trips back to that exact callsign. Covers the homophone variants
  // too since englishDigitSpokenVariants includes won/too/to/tree/for/fore/fower/fife/ate/niner.
  @Test func englishSpellingRoundTripsToCallsign() {
    var rng = SeededGenerator(seed: 0x9E_01_0001)
    var exercised = 0
    for _ in 0..<300 {
      let cs = randomCallsign(using: &rng)
      let spoken = englishSpell(cs, using: &rng)
      #expect(
        PhoneticCallsignParser.parse(spoken) == cs,
        "english spelling '\(spoken)' must parse to \(cs)")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // French spelling under fr-FR (B1 fold path, B7 french locale, B10 frenchDigits, B9 tokenMap for
  // shared ICAO letters/SIX) round-trips. Exercises the diacritic fold (zero/unite) + x-ray merge.
  @Test func frenchSpellingRoundTripsInFrenchLocale() {
    var rng = SeededGenerator(seed: 0x9E_02_0002)
    var exercised = 0
    for _ in 0..<300 {
      let cs = randomCallsign(using: &rng)
      let spoken = frenchSpell(cs, using: &rng)
      #expect(
        PhoneticCallsignParser.parse(spoken, localeIdentifier: "fr-FR") == cs,
        "french spelling '\(spoken)' must parse to \(cs) under fr-FR")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // Each single English homophone token (B9 tokenMap hit) maps to EXACTLY its one expected digit —
  // pins won->1, too/to->2, tree->3, for/fore/fower->4, fife->5, ate->8, niner->9 directionally.
  @Test func eachEnglishHomophoneMapsToItsDigit() {
    var rng = SeededGenerator(seed: 0x9E_03_0003)
    let pairs: [(String, String)] =
      englishDigitSpokenVariants.sorted { $0.key < $1.key }.flatMap { digit, words in
        words.map { ($0, String(digit)) }
      }
    var exercised = 0
    for _ in 0..<300 {
      let (word, expected) = pairs.randomElement(using: &rng)!
      #expect(
        PhoneticCallsignParser.parse(word) == expected,
        "homophone '\(word)' must parse to \(expected)")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // Fixed point within two applications: parse(parse(parse(x))) == parse(parse(x)) for ANY x.
  // Single-application idempotence is NOT a current contract: a pure-letter compact output that
  // spells an English digit homophone re-maps on a second parse (letters T,O -> "TO" -> "2") —
  // that behavior is part of the OPEN owner decision on homophone scope and is
  // pinned as a known issue below, not silently exempted. Production parses raw dictation exactly
  // once (VoiceFilterSettingsSection), so the divergence is a latent re-normalization hazard.
  @Test func parseReachesAFixedPointWithinTwoApplications() {
    var rng = SeededGenerator(seed: 0x9E_04_0004)
    let localeChoices: [String?] = [nil, "en-US", "fr-FR"]
    // why: the arbitrary generator almost never assembles a pure-letter output that spells an
    // English digit homophone (the divergence class this property covers), so the reach floor is
    // anchored by deterministic exemplars driven through the SAME property — a purely random floor
    // here would be vacuous.
    let divergenceExemplars = [
      "tango oscar",  // -> TO -> 2
      "whiskey oscar november",  // -> WON -> 1
      "tango oscar oscar",  // -> TOO -> 2
      "alpha tango echo",  // -> ATE -> 8
      "foxtrot oscar romeo",  // -> FOR -> 4
    ]
    var singleApplicationDivergences = 0
    var probes: [(text: String, locale: String?)] = divergenceExemplars.map { ($0, nil) }
    for _ in 0..<300 {
      probes.append((arbitraryText(using: &rng), localeChoices.randomElement(using: &rng)!))
    }
    for (text, locale) in probes {
      let once = PhoneticCallsignParser.parse(text, localeIdentifier: locale)
      let twice = PhoneticCallsignParser.parse(once, localeIdentifier: locale)
      let thrice = PhoneticCallsignParser.parse(twice, localeIdentifier: locale)
      if twice != once { singleApplicationDivergences += 1 }
      #expect(
        thrice == twice,
        "no fixed point by 2nd parse: '\(text)' -> '\(once)' -> '\(twice)' -> '\(thrice)' [\(locale ?? "nil")]"
      )
    }
    #expect(singleApplicationDivergences >= divergenceExemplars.count)
  }

  // Known issue (red-when-fixed marker): the parser's English homophone table re-maps its own
  // compact output — letters T,O parse to "TO", and re-parsing "TO" yields "2". Whether homophone
  // digits should apply to bare letter sequences is the OPEN owner decision on homophone scope;
  // when that lands and parse becomes idempotent, this withKnownIssue fails and the fixed-point
  // property above should be tightened back to single-application idempotence.
  @Test func parseCompactLetterOutputHomophoneRemapIsAKnownOpenIssue() {
    let once = PhoneticCallsignParser.parse("tango oscar")
    #expect(once == "TO")
    withKnownIssue {
      let reparsed = PhoneticCallsignParser.parse(once)
      #expect(reparsed == once, "expected idempotence; got '\(once)' -> '\(reparsed)'")
    }
  }

  // Output is ALWAYS uppercase alphanumeric-only (B19 alnum passthrough + B20 uppercase), for any
  // input and any locale. Non-alphanumerics never survive; nothing lowercase escapes.
  @Test func outputIsAlwaysUppercaseAlphanumeric() {
    var rng = SeededGenerator(seed: 0x9E_05_0005)
    let localeChoices: [String?] = [nil, "en-US", "fr-FR", "de-DE", ""]
    for _ in 0..<300 {
      let text = arbitraryText(using: &rng)
      let locale = localeChoices.randomElement(using: &rng)!
      let out = PhoneticCallsignParser.parse(text, localeIdentifier: locale)
      #expect(
        isAlphanumericUppercase(out),
        "output not uppercase-alnum: '\(out)' from '\(text)' [\(locale ?? "nil")]")
    }
  }

  // Separator-only / empty garbage (B5 single-append path, B19 passthrough finds nothing) -> "".
  @Test func separatorOnlyGarbageYieldsEmpty() {
    var rng = SeededGenerator(seed: 0x9E_06_0006)
    let localeChoices: [String?] = [nil, "en-US", "fr-FR"]
    for _ in 0..<300 {
      let garbage = separatorGarbage(using: &rng)
      let locale = localeChoices.randomElement(using: &rng)!
      #expect(
        PhoneticCallsignParser.parse(garbage, localeIdentifier: locale).isEmpty,
        "garbage '\(garbage)' must parse empty [\(locale ?? "nil")]")
    }
  }

  // French-only digit words (sept/huit/deux/...) DO decode under fr-FR (B10) but FALL BACK to a
  // literal passthrough under the default/English path (B11 nil -> B19), so the two locales diverge
  // as the SUT specifies. Pins both branch outcomes of lookupToken's French arm.
  @Test func frenchDigitWordsDecodeOnlyUnderFrenchLocale() {
    var rng = SeededGenerator(seed: 0x9E_07_0007)
    let frenchOnly = ["sept", "huit", "deux", "trois", "quatre", "cinq", "neuf", "un"]
    let expectedDigit = [
      "sept": "7", "huit": "8", "deux": "2", "trois": "3",
      "quatre": "4", "cinq": "5", "neuf": "9", "un": "1",
    ]
    var exercised = 0
    for _ in 0..<300 {
      let word = frenchOnly.randomElement(using: &rng)!
      #expect(
        PhoneticCallsignParser.parse(word, localeIdentifier: "fr-FR") == expectedDigit[word]!,
        "'\(word)' must decode to \(expectedDigit[word]!) under fr-FR")
      #expect(
        PhoneticCallsignParser.parse(word) == word.uppercased(),
        "'\(word)' must pass through literally under default locale")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // French decimal/comma fillers DECIMALE/VIRGULE are dropped under fr-FR (B12 -> "" mapped, B18
  // appends empty) while surrounding letters survive — they contribute nothing to the callsign.
  @Test func frenchDecimalFillersAreDroppedUnderFrenchLocale() {
    var rng = SeededGenerator(seed: 0x9E_08_0008)
    let fillers = ["decimale", "virgule", "décimale"]
    var exercised = 0
    for _ in 0..<300 {
      let cs = randomCallsign(using: &rng)
      let plain = frenchSpell(cs, using: &rng)
      let filler = fillers.randomElement(using: &rng)!
      let withFiller = "\(filler) \(plain) \(filler)"
      #expect(
        PhoneticCallsignParser.parse(withFiller, localeIdentifier: "fr-FR") == cs,
        "fillers around '\(plain)' must vanish, expected \(cs)")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // "oh" between two decodable tokens becomes 0 (B13). Building <token> oh <token> from a known
  // English-digit word on each side forces both prev and next to decode, so the middle "oh" -> "0".
  @Test func ohBecomesZeroBetweenDecodableTokens() {
    var rng = SeededGenerator(seed: 0x9E_09_0009)
    let neighbors = englishDigitSpokenVariants.values.joined() + letterSpokenVariants["A"]!
    let neighborArray = Array(neighbors)
    var exercised = 0
    for _ in 0..<300 {
      let lead = neighborArray.randomElement(using: &rng)!
      let trail = neighborArray.randomElement(using: &rng)!
      // why: x-ray variants would merge with a neighboring "ray"; the chosen pool has none.
      let out = PhoneticCallsignParser.parse("\(lead) oh \(trail)")
      let leadOut = PhoneticCallsignParser.parse(lead)
      let trailOut = PhoneticCallsignParser.parse(trail)
      #expect(
        out == "\(leadOut)0\(trailOut)",
        "'\(lead) oh \(trail)' must place 0 for oh -> \(leadOut)0\(trailOut), got \(out)")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // "oh" with NO decodable neighbor (isolated, or surrounded by unknown words) stays literal OH
  // (B14 nil -> B19 passthrough). Conservative: the parse must CONTAIN "OH" and never a "0".
  @Test func ohStaysLiteralWithoutDecodableNeighbor() {
    var rng = SeededGenerator(seed: 0x9E_0A_000A)
    // why: not in tokenMap and never form an x/ex + ray merge, so they stay literal passthrough.
    let nonDecodable = ["say", "lufthansa", "heavy", "the", "and", "zzz", "qqq"]
    var exercised = 0
    for _ in 0..<300 {
      let pick = Int.random(in: 0...2, using: &rng)
      let text: String
      switch pick {
      case 0: text = "oh"
      case 1: text = "\(nonDecodable.randomElement(using: &rng)!) oh"
      default:
        text =
          "\(nonDecodable.randomElement(using: &rng)!) oh "
          + "\(nonDecodable.randomElement(using: &rng)!)"
      }
      let out = PhoneticCallsignParser.parse(text)
      #expect(out.contains("OH"), "'\(text)' must keep OH literal, got \(out)")
      #expect(!out.contains("0"), "'\(text)' must not produce 0 for oh, got \(out)")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // x/ex + "ray" merge (B3/B4): "x ray", "x-ray", "ex ray", "ex-ray", "xray", "exray" all decode to
  // the single letter X, regardless of separator between the two raw tokens.
  @Test func xRayVariantsAllDecodeToX() {
    var rng = SeededGenerator(seed: 0x9E_0B_000B)
    let separators = [" ", "-", ".", "  ", " . ", "/"]
    var exercised = 0
    for _ in 0..<300 {
      let stem = Bool.random(using: &rng) ? "x" : "ex"
      let merged = Bool.random(using: &rng)
      let text: String
      if merged {
        text = "\(stem)ray"  // "xray" / "exray"
      } else {
        text = "\(stem)\(separators.randomElement(using: &rng)!)ray"
      }
      #expect(
        PhoneticCallsignParser.parse(text) == "X",
        "'\(text)' must decode to X")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // localeIdentifier == nil (B6) and any non-"fr" identifier (B8) take the SAME English path: for
  // English/unknown text, the parse under nil equals the parse under en-US / de-DE / "". This pins
  // the non-French branch of isFrenchLocale and the un-folded token path agreeing across locales.
  @Test func nonFrenchLocalesAgreeWithDefault() {
    var rng = SeededGenerator(seed: 0x9E_0C_000C)
    for _ in 0..<300 {
      let cs = randomCallsign(using: &rng)
      let text = englishSpell(cs, using: &rng)
      let base = PhoneticCallsignParser.parse(text, localeIdentifier: nil)
      for locale in ["en-US", "en", "de-DE", ""] {
        #expect(
          PhoneticCallsignParser.parse(text, localeIdentifier: locale) == base,
          "non-french locale '\(locale)' diverged from nil on '\(text)'")
      }
    }
  }

  // Unknown (non-token) words fall back to alphanumeric passthrough (B15 lookup nil -> B19):
  // uppercased and stripped of non-alnum. Interleaving an unknown word between decodable tokens
  // preserves the decode of those tokens AND the uppercased unknown literal.
  @Test func unknownWordsPassThroughUppercasedAlnum() {
    var rng = SeededGenerator(seed: 0x9E_0D_000D)
    let unknowns = ["lufthansa", "speedbird", "qatari", "n123", "27r", "zzz9"]
    var exercised = 0
    for _ in 0..<300 {
      let letter = letterSpokenVariants.keys.sorted().randomElement(using: &rng)!
      let letterWord = letterSpokenVariants[letter]!.randomElement(using: &rng)!
      // why: avoid x-ray-mergeable letterWord adjacency to "ray"; unknowns here contain no "ray".
      let unknown = unknowns.randomElement(using: &rng)!
      let out = PhoneticCallsignParser.parse("\(letterWord) \(unknown)")
      let expectedUnknown = unknown.uppercased().filter { $0.isLetter || $0.isNumber }
      #expect(
        out == "\(letter)\(expectedUnknown)",
        "'\(letterWord) \(unknown)' must be \(letter)\(expectedUnknown), got \(out)")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // Determinism: the parser is a pure function — repeated calls on identical input + locale agree.
  @Test func parseIsDeterministic() {
    var rng = SeededGenerator(seed: 0x9E_0E_000E)
    let localeChoices: [String?] = [nil, "en-US", "fr-FR", "de-DE"]
    for _ in 0..<300 {
      let text = arbitraryText(using: &rng)
      let locale = localeChoices.randomElement(using: &rng)!
      #expect(
        PhoneticCallsignParser.parse(text, localeIdentifier: locale)
          == PhoneticCallsignParser.parse(text, localeIdentifier: locale))
    }
  }
}
