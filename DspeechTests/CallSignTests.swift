import Foundation
import Testing

@testable import Dspeech

struct CallSignTests {
  @Test func emptyOrPunctuationOnlyFailsInit() {
    #expect(CallSign(raw: "") == nil)
    #expect(CallSign(raw: "   ") == nil)
    #expect(CallSign(raw: "!!!") == nil)
  }

  @Test func normalizationStripsSeparators() throws {
    let cs = try #require(CallSign(raw: " n-123 a/b "))
    #expect(cs.normalized == "N123AB")
    #expect(cs.raw == "n-123 a/b")
  }

  @Test func phoneticExpansionCoversDigitsAndLetters() throws {
    let cs = try #require(CallSign(raw: "N9A"))
    #expect(cs.phoneticTokens == ["NOVEMBER", "NINER", "ALPHA"])
  }

  @Test func directNormalizedMatchInText() throws {
    let cs = try #require(CallSign(raw: "N123AB"))
    #expect(cs.matches(in: "Tower, N123AB ready for departure"))
    #expect(cs.matches(in: "n123ab cleared for takeoff"))
  }

  @Test func compactTailNumberWithDashesMatches() throws {
    let cs = try #require(CallSign(raw: "N123AB"))
    #expect(cs.matches(in: "calling N-123-AB on approach"))
  }

  @Test func fastPathDoesNotConcatenateAcrossWordBoundaries() throws {
    let cs = try #require(CallSign(raw: "N23AB"))
    #expect(cs.matches(in: "calling N-23-AB on approach"))
    #expect(cs.matches(in: "company N2. 3AB was heard earlier") == false)
  }

  @Test func phoneticVariantMatchesOrdered() throws {
    let cs = try #require(CallSign(raw: "N12A"))
    #expect(cs.matches(in: "November One Two Alpha, descend three thousand"))
  }

  @Test func phoneticDoesNotMatchWrongOrder() throws {
    let cs = try #require(CallSign(raw: "N12A"))
    #expect(cs.matches(in: "Alpha Two One November contact ground") == false)
  }

  // why: the on-device recognizer (dictation + addsPunctuation) renders the spoken callsign as a
  // MIX of phonetic letters and NUMERALS — this is the realistic transcript shape, and the prior
  // matcher returned false for it, silently suppressing the most safety-critical own-callsign call.
  @Test func numeralMixedPhoneticMatches() throws {
    let cs = try #require(CallSign(raw: "N123AB"))
    #expect(cs.matches(in: "November 123 Alpha Bravo, descend three thousand"))
    #expect(cs.matches(in: "november 123 alpha bravo cleared to land"))
  }

  @Test func numeralMixedMatchesWithLeadingAirlineWord() throws {
    let cs = try #require(CallSign(raw: "N123AB"))
    // a non-decodable leading word (e.g. an airline/operator word) must not break the match
    #expect(cs.matches(in: "Cessna November 123 Alpha Bravo hold short runway 27"))
  }

  @Test func fullySpelledOutDigitsStillMatch() throws {
    let cs = try #require(CallSign(raw: "N123AB"))
    #expect(cs.matches(in: "November One Two Three Alpha Bravo line up and wait"))
  }

  @Test func frenchSpokenCallSignMatchesWhenLocaleIsFrench() throws {
    let cs = try #require(CallSign(raw: "FGO78"))
    #expect(
      cs.matches(
        in: "Tour, Foxtrot Golf Oscar sept huit, autorisé atterrissage piste deux six",
        localeIdentifier: "fr-FR"
      ))
  }

  @Test func frenchAbbreviatedCallSignMatchesWhenLocaleIsFrench() throws {
    let cs = try #require(CallSign(raw: "FGO78"))
    #expect(cs.matchesAbbreviated(in: "sept huit, rappelez finale", localeIdentifier: "fr-FR"))
  }

  @Test func frenchOnlyDigitWordsDoNotMatchWithoutFrenchLocale() throws {
    let cs = try #require(CallSign(raw: "FGO78"))
    #expect(cs.matches(in: "Foxtrot Golf Oscar sept huit") == false)
  }

  @Test func everydayNineSpellingMatches() throws {
    // the recognizer emits "nine", not the ICAO "niner"
    let cs = try #require(CallSign(raw: "N9A"))
    #expect(cs.matches(in: "November Nine Alpha contact tower"))
  }

  @Test(arguments: [
    "November Three Alpha Bravo",
    "Three Alpha Bravo",
    "N3AB",
    "Two Three Alpha Bravo",
    "Cessna Three Alpha Bravo",
  ])
  func abbreviatedOwnCallSignMatches(_ transcript: String) throws {
    let cs = try #require(CallSign(raw: "N123AB"))
    #expect(cs.matchesAbbreviated(in: transcript))
  }

  @Test func abbreviatedTailDoesNotPromoteFullMatch() throws {
    // why: matches(in:) stays the strict full-callsign tier — the display-biased
    // abbreviated tier must never be able to feed a suppression-grade decision.
    let cs = try #require(CallSign(raw: "N123AB"))
    #expect(cs.matches(in: "Three Alpha Bravo") == false)
  }

  @Test func abbreviatedTailInsideLongerRunDoesNotMatch() throws {
    // "November Niner Eight Seven Alpha Bravo" is a DIFFERENT aircraft whose callsign
    // merely contains the own tail; a complete-run match must reject it.
    let cs = try #require(CallSign(raw: "N123AB"))
    #expect(cs.matchesAbbreviated(in: "November Niner Eight Seven Alpha Bravo") == false)
  }

  @Test func abbreviatedOtherCallSignDoesNotMatchWhenTailDoesNotCollide() throws {
    let cs = try #require(CallSign(raw: "N123AB"))
    #expect(cs.matches(in: "November Niner Niner Charlie Delta") == false)
  }

  @Test(arguments: [
    "November Tree Alfa Bravo",
    "November Three Alpha Bravo",
    "November Three Juliett Bravo",
    "November Three Juliet Bravo",
    "November Three Whisky Bravo",
    "November Three Whiskey Bravo",
    "November Three Xray Bravo",
    "November Three X-ray Bravo",
    "November Three X ray Bravo",
    "November Fower Fife Niner Alfa",
    "November Oh Seven Alfa",
  ])
  func phoneticVariantDecodeMatchesCallSign(_ transcript: String) throws {
    let expected: String
    if transcript.contains("Juliett") || transcript.contains("Juliet") {
      expected = "N3JB"
    } else if transcript.contains("Whisky") || transcript.contains("Whiskey") {
      expected = "N3WB"
    } else if transcript.contains("X") {
      expected = "N3XB"
    } else if transcript.contains("Fower") {
      expected = "N459A"
    } else if transcript.contains("Oh") {
      expected = "N07A"
    } else {
      expected = "N3AB"
    }
    let cs = try #require(CallSign(raw: expected))
    #expect(cs.matches(in: transcript))
  }

  @Test func decodeRunDoesNotBridgeAcrossNonCallsignWord() throws {
    let cs = try #require(CallSign(raw: "N12A"))
    // a non-decodable word between "November" and the spelled-out digits breaks the decode run,
    // so the fragments must not bridge into N12A (spelled-out digits keep the compact alphanumeric
    // form clear of "N12A" too, so this exercises the run logic rather than the verbatim fast path)
    #expect(cs.matches(in: "November maintain one two alpha") == false)
  }

  @Test func noMatchInUnrelatedText() throws {
    let cs = try #require(CallSign(raw: "N123AB"))
    #expect(cs.matches(in: "United 247 contact ground point niner") == false)
  }

  @Test func compactsSpokenCallSignToRegistration() throws {
    let cs = try #require(CallSign(raw: "A123B"))
    #expect(cs.compacted(in: "Alpha one two three Bravo") == "A123B")
    #expect(cs.compacted(in: "Alpha 1 2 3 Bravo") == "A123B")
    #expect(cs.compacted(in: "Alpha 123 Bravo") == "A123B")
  }

  @Test func compactsCallSignInsideLongerTransmission() throws {
    let cs = try #require(CallSign(raw: "A123B"))
    #expect(
      cs.compacted(in: "Tower Alpha 1 2 3 Bravo descend four thousand")
        == "Tower A123B descend four thousand")
    // trailing read-back digits (heading/squawk) stay separate; only the call sign compacts
    #expect(cs.compacted(in: "Alpha 1 2 3 Bravo squawk 7000") == "A123B squawk 7000")
  }

  @Test func compactsEveryOccurrenceAndLeavesOtherTextUntouched() throws {
    let cs = try #require(CallSign(raw: "A123B"))
    #expect(
      cs.compacted(in: "Alpha 1 2 3 Bravo, roger, Alpha 1 2 3 Bravo") == "A123B, roger, A123B")
    #expect(cs.compacted(in: "Cleared for takeoff") == "Cleared for takeoff")
    #expect(cs.compacted(in: "November Oscar Papa Quebec") == "November Oscar Papa Quebec")
  }

  @Test func compactsLetterOnlyAndXRayCallSigns() throws {
    let abc = try #require(CallSign(raw: "ABC"))
    #expect(abc.compacted(in: "Alpha bravo Charlie Delta Echo") == "ABC Delta Echo")
    let xyz = try #require(CallSign(raw: "XYZ"))
    #expect(xyz.compacted(in: "report X-ray Yankee Zulu") == "report XYZ")
  }

  @Test func phoneticExpansionCoversFullAlphabet() throws {
    let cs = try #require(CallSign(raw: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    #expect(
      cs.phoneticTokens == [
        "ALPHA", "BRAVO", "CHARLIE", "DELTA", "ECHO", "FOXTROT", "GOLF", "HOTEL", "INDIA",
        "JULIETT", "KILO", "LIMA", "MIKE", "NOVEMBER", "OSCAR", "PAPA", "QUEBEC", "ROMEO",
        "SIERRA", "TANGO", "UNIFORM", "VICTOR", "WHISKEY", "XRAY", "YANKEE", "ZULU",
      ])
  }

  @Test func phoneticExpansionCoversAllDigits() throws {
    let cs = try #require(CallSign(raw: "0123456789"))
    #expect(
      cs.phoneticTokens == [
        "ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINER",
      ])
  }

  @Test("should preserve callsign matching across 1000 generated spoken registrations")
  func shouldPreserveCallSignMatchingAcross1000GeneratedSpokenRegistrations() throws {
    let generatedCaseCount = 1_000
    var random = DeterministicCallSignRandom(seed: 0xD5_06_11_03)

    for _ in 0..<generatedCaseCount {
      let registration = Self.registration(random: &random)
      let callSign = try #require(CallSign(raw: registration))
      let spoken = Self.render(registration: registration, random: &random)
      #expect(callSign.matches(in: spoken) || callSign.matchesAbbreviated(in: spoken))

      let other = Self.nonCollidingRegistration(with: registration, random: &random)
      let otherSpoken = Self.render(registration: other, random: &random)
      #expect(callSign.matches(in: otherSpoken) == false)
      #expect(callSign.matchesAbbreviated(in: otherSpoken) == false)
    }

    print("PBT_CASE_COUNT callsign=1000")
    #expect(generatedCaseCount == 1_000)
  }

  @Test("should keep generated abbreviated callsigns out of the full-match tier")
  func shouldKeepGeneratedAbbreviatedCallSignsOutOfFullMatchTier() throws {
    let generatedCaseCount = 500
    var random = DeterministicCallSignRandom(seed: 0xD5_06_11_04)

    for _ in 0..<generatedCaseCount {
      let registration = Self.registration(random: &random)
      let callSign = try #require(CallSign(raw: registration))
      let suffix = Array(callSign.normalized.dropFirst())
      guard suffix.count >= 2 else {
        Issue.record("generated registration must include an abbreviated suffix")
        return
      }
      let tailLength = random.int(in: 2...suffix.count)
      let tail = String(suffix.suffix(tailLength))
      let spokenTail = tail.map {
        Self.spokenToken(for: $0, random: &random)
      }.joined(separator: " ")

      #expect(callSign.matches(in: spokenTail) == false)
      #expect(callSign.matchesAbbreviated(in: spokenTail))
    }

    print("PBT_CASE_COUNT callsign-abbreviation-tier=500")
    #expect(generatedCaseCount == 500)
  }

  @Test("should preserve French callsign matching across 500 generated spoken registrations")
  func shouldPreserveFrenchCallSignMatchingAcross500GeneratedSpokenRegistrations() throws {
    let generatedCaseCount = 500
    var random = DeterministicCallSignRandom(seed: 0xD5_06_12_05)

    for _ in 0..<generatedCaseCount {
      let registration = Self.registration(random: &random)
      let callSign = try #require(CallSign(raw: registration))
      let spoken = Self.renderFrench(registration: registration, random: &random)
      #expect(callSign.matches(in: spoken, localeIdentifier: "fr-FR"))

      let other = Self.nonCollidingRegistration(with: registration, random: &random)
      let otherSpoken = Self.renderFrench(registration: other, random: &random)
      #expect(callSign.matches(in: otherSpoken, localeIdentifier: "fr-FR") == false)
      #expect(callSign.matchesAbbreviated(in: otherSpoken, localeIdentifier: "fr-FR") == false)
    }

    print("PBT_CASE_COUNT callsign-fr=500")
    #expect(generatedCaseCount == 500)
  }

  private struct DeterministicCallSignRandom {
    private var state: UInt64

    init(seed: UInt64) {
      self.state = seed
    }

    mutating func next() -> UInt64 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return state
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
      let span = UInt64(range.upperBound - range.lowerBound + 1)
      return range.lowerBound + Int(next() % span)
    }

    mutating func bool() -> Bool {
      next().isMultiple(of: 2)
    }
  }

  private static let registrationPrefixes = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
  private static let registrationTailCharacters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

  private static func registration(random: inout DeterministicCallSignRandom) -> String {
    let prefix = registrationPrefixes[random.int(in: 0...(registrationPrefixes.count - 1))]
    let tailCount = random.int(in: 1...4)
    var result = String(prefix)
    for _ in 0..<tailCount {
      let next = registrationTailCharacters[
        random.int(in: 0...(registrationTailCharacters.count - 1))]
      result.append(next)
    }
    return result
  }

  private static func nonCollidingRegistration(
    with registration: String,
    random: inout DeterministicCallSignRandom
  ) -> String {
    let ownKeys = matchKeys(for: registration)
    while true {
      let candidate = Self.registration(random: &random)
      if candidate != registration, ownKeys.isDisjoint(with: matchKeys(for: candidate)) {
        return candidate
      }
    }
  }

  private static func render(
    registration: String,
    random: inout DeterministicCallSignRandom
  ) -> String {
    let characters = Array(registration)
    let suffix = Array(characters.dropFirst())
    let useAbbreviation = suffix.count >= 2 && random.int(in: 0...2) != 0
    let selected: [Character]
    if useAbbreviation {
      let tailLength = random.int(in: 2...suffix.count)
      let tail = Array(suffix.suffix(tailLength))
      selected = random.bool() ? [characters[0]] + tail : tail
    } else {
      selected = characters
    }

    if random.int(in: 0...3) == 0 {
      return String(selected)
    }
    return selected.map { spokenToken(for: $0, random: &random) }.joined(separator: " ")
  }

  private static func renderFrench(
    registration: String,
    random: inout DeterministicCallSignRandom
  ) -> String {
    Array(registration).map { frenchSpokenToken(for: $0, random: &random) }.joined(separator: " ")
  }

  private static func spokenToken(
    for character: Character,
    random: inout DeterministicCallSignRandom
  ) -> String {
    let variants: [String]
    switch character {
    case "A": variants = ["Alpha", "Alfa"]
    case "B": variants = ["Bravo"]
    case "C": variants = ["Charlie"]
    case "D": variants = ["Delta"]
    case "E": variants = ["Echo"]
    case "F": variants = ["Foxtrot"]
    case "G": variants = ["Golf"]
    case "H": variants = ["Hotel"]
    case "I": variants = ["India"]
    case "J": variants = ["Juliett", "Juliet"]
    case "K": variants = ["Kilo"]
    case "L": variants = ["Lima"]
    case "M": variants = ["Mike"]
    case "N": variants = ["November"]
    case "O": variants = ["Oscar"]
    case "P": variants = ["Papa"]
    case "Q": variants = ["Quebec"]
    case "R": variants = ["Romeo"]
    case "S": variants = ["Sierra"]
    case "T": variants = ["Tango"]
    case "U": variants = ["Uniform"]
    case "V": variants = ["Victor"]
    case "W": variants = ["Whiskey", "Whisky"]
    case "X": variants = ["Xray", "X-ray", "X ray"]
    case "Y": variants = ["Yankee"]
    case "Z": variants = ["Zulu"]
    case "0": variants = ["Zero", "Oh"]
    case "1": variants = ["One"]
    case "2": variants = ["Two"]
    case "3": variants = ["Three", "Tree"]
    case "4": variants = ["Four", "Fower"]
    case "5": variants = ["Five", "Fife"]
    case "6": variants = ["Six"]
    case "7": variants = ["Seven"]
    case "8": variants = ["Eight"]
    case "9": variants = ["Nine", "Niner"]
    default: variants = [String(character)]
    }
    return variants[random.int(in: 0...(variants.count - 1))]
  }

  private static func frenchSpokenToken(
    for character: Character,
    random: inout DeterministicCallSignRandom
  ) -> String {
    let variants: [String]
    switch character {
    case "A": variants = ["Alpha", "Alfa"]
    case "B": variants = ["Bravo"]
    case "C": variants = ["Charlie"]
    case "D": variants = ["Delta"]
    case "E": variants = ["Echo"]
    case "F": variants = ["Foxtrot"]
    case "G": variants = ["Golf"]
    case "H": variants = ["Hotel"]
    case "I": variants = ["India"]
    case "J": variants = ["Juliett", "Juliet"]
    case "K": variants = ["Kilo"]
    case "L": variants = ["Lima"]
    case "M": variants = ["Mike"]
    case "N": variants = ["November"]
    case "O": variants = ["Oscar"]
    case "P": variants = ["Papa"]
    case "Q": variants = ["Quebec"]
    case "R": variants = ["Romeo"]
    case "S": variants = ["Sierra"]
    case "T": variants = ["Tango"]
    case "U": variants = ["Uniform"]
    case "V": variants = ["Victor"]
    case "W": variants = ["Whiskey", "Whisky"]
    case "X": variants = ["Xray", "X-ray", "X ray"]
    case "Y": variants = ["Yankee"]
    case "Z": variants = ["Zulu"]
    case "0": variants = ["Zéro", "Zero"]
    case "1": variants = ["Un", "Unité"]
    case "2": variants = ["Deux"]
    case "3": variants = ["Trois"]
    case "4": variants = ["Quatre"]
    case "5": variants = ["Cinq"]
    case "6": variants = ["Six"]
    case "7": variants = ["Sept"]
    case "8": variants = ["Huit"]
    case "9": variants = ["Neuf"]
    default: variants = [String(character)]
    }
    return variants[random.int(in: 0...(variants.count - 1))]
  }

  private static func matchKeys(for registration: String) -> Set<String> {
    let normalized = CallSign.normalize(registration)
    let suffix = String(normalized.dropFirst())
    var keys: Set<String> = [normalized]
    if let prefix = normalized.first, suffix.count >= 2 {
      for length in 2...suffix.count {
        let tail = String(suffix.suffix(length))
        keys.insert(tail)
        keys.insert(String(prefix) + tail)
      }
    }
    return keys
  }

  // why: regression — the full call-sign must match a run that EQUALS it or is it followed by a
  // DIGIT (own read-back number). It must NOT match traffic addressed to ANOTHER aircraft whose
  // decoded run merely contains ours embedded (mid/suffix) or extended by more phonetic letters.
  // Found by adversarial review 2026-06-13.
  @Test func ownCallSignFollowedByReadbackDigitsMatches() throws {
    let cs = try #require(CallSign(raw: "N123AB"))
    #expect(cs.matches(in: "November one two three alpha bravo two seven"))
    #expect(cs.matches(in: "November one two three alpha bravo, descend three thousand"))
  }

  @Test func otherAircraftContainingOwnCallSignDoesNotMatch() throws {
    let cs = try #require(CallSign(raw: "N2AB"))
    // ours embedded mid-run (Delta November Two Alpha Bravo Niner == DN2AB9)
    #expect(!cs.matches(in: "Delta November two alpha bravo niner, descend two thousand"))
    // ours extended by another phonetic letter (November Two Alpha Bravo Charlie == N2ABC)
    #expect(!cs.matches(in: "November two alpha bravo charlie, contact tower"))
  }
}
