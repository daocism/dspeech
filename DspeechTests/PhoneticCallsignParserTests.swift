import Foundation
import Testing

@testable import Dspeech

struct PhoneticCallsignParserTests {
  @Test func parsesFullPhoneticTailNumber() {
    #expect(PhoneticCallsignParser.parse("november one two three alpha bravo") == "N123AB")
  }

  @Test func parsesAviationDigitVariants() {
    #expect(PhoneticCallsignParser.parse("tree fife fower niner") == "3549")
  }

  @Test func parsesMixedSpokenAndLiteral() {
    #expect(PhoneticCallsignParser.parse("speedbird 247") == "SPEEDBIRD247")
  }

  @Test func stripsPunctuationAndCollapses() {
    #expect(PhoneticCallsignParser.parse("N-123, alpha. bravo!") == "N123AB")
  }

  @Test func parsesHyphenatedXray() {
    #expect(PhoneticCallsignParser.parse("x-ray yankee zulu") == "XYZ")
  }

  @Test func parsesSeparatedXRay() {
    #expect(PhoneticCallsignParser.parse("x ray yankee zulu") == "XYZ")
  }

  @Test func emptyInputYieldsEmpty() {
    #expect(PhoneticCallsignParser.parse("   ") == "")
  }

  @Test func resultFeedsCallSignParser() {
    let parsed = PhoneticCallsignParser.parse("romeo alpha eight nine zero seven seven")
    let callsign = CallSign(raw: parsed)
    #expect(callsign?.normalized == "RA89077")
  }

  @Test func parsesFrenchFullPhoneticCallsignWhenLocaleIsFrench() {
    #expect(
      PhoneticCallsignParser.parse(
        "foxtrot golf oscar alpha bravo",
        localeIdentifier: "fr-FR"
      ) == "FGOAB")
  }

  @Test func parsesFrenchLettersAndDigitWordsWhenLocaleIsFrench() {
    #expect(
      PhoneticCallsignParser.parse(
        "foxtrot golf oscar sept huit",
        localeIdentifier: "fr"
      ) == "FGO78")
  }

  @Test func foldsFrenchDigitDiacriticsWhenLocaleIsFrench() {
    #expect(PhoneticCallsignParser.parse("zéro zero", localeIdentifier: "fr-FR") == "00")
  }

  @Test func parsesFrenchUniteVariantWhenLocaleIsFrench() {
    #expect(PhoneticCallsignParser.parse("unité", localeIdentifier: "fr-FR") == "1")
  }

  @Test func ignoresFrenchDecimalSeparatorsWhenLocaleIsFrench() {
    #expect(
      PhoneticCallsignParser.parse(
        "foxtrot décimale golf virgule oscar",
        localeIdentifier: "fr-FR"
      ) == "FGO")
  }

  @Test func frenchOnlyDigitWordsDoNotChangeDefaultLocalePath() {
    #expect(PhoneticCallsignParser.parse("foxtrot sept huit") == "FSEPTHUIT")
  }

  @Test func caseInsensitiveTokens() {
    #expect(PhoneticCallsignParser.parse("NOVEMBER One Two Three") == "N123")
  }

  @Test(arguments: [
    ("alpha", "A"), ("alfa", "A"), ("bravo", "B"), ("charlie", "C"), ("delta", "D"),
    ("echo", "E"), ("foxtrot", "F"), ("fox", "F"), ("golf", "G"), ("hotel", "H"),
    ("india", "I"), ("juliett", "J"), ("juliet", "J"), ("kilo", "K"), ("lima", "L"),
    ("mike", "M"), ("november", "N"), ("oscar", "O"), ("papa", "P"), ("quebec", "Q"),
    ("romeo", "R"), ("sierra", "S"), ("tango", "T"), ("uniform", "U"), ("victor", "V"),
    ("whiskey", "W"), ("whisky", "W"), ("xray", "X"), ("x-ray", "X"), ("ex-ray", "X"),
    ("yankee", "Y"), ("zulu", "Z"),
    ("zero", "0"), ("one", "1"), ("won", "1"), ("two", "2"), ("too", "2"),
    ("to", "2"), ("three", "3"), ("tree", "3"), ("four", "4"), ("fower", "4"), ("for", "4"),
    ("fore", "4"),
    ("five", "5"), ("fife", "5"), ("six", "6"), ("seven", "7"), ("eight", "8"), ("ate", "8"),
    ("nine", "9"), ("niner", "9"),
  ])
  func parsesEveryIcaoTokenVariant(_ pair: (spoken: String, expected: String)) {
    #expect(PhoneticCallsignParser.parse(pair.spoken) == pair.expected)
  }

  @Test func parsesOhAsZeroInsideCallsignTailContext() {
    #expect(PhoneticCallsignParser.parse("november oh seven alpha") == "N07A")
    #expect(PhoneticCallsignParser.parse("oh seven alpha") == "07A")
  }

  @Test func preservesOhOutsideCallsignTailContext() {
    #expect(PhoneticCallsignParser.parse("oh") == "OH")
    #expect(PhoneticCallsignParser.parse("say oh") == "SAYOH")
  }

  @Test func parsesFullAlphabetSentence() {
    let spoken =
      "alpha bravo charlie delta echo foxtrot golf hotel india juliett kilo lima mike "
      + "november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu"
    #expect(PhoneticCallsignParser.parse(spoken) == "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
  }

  @Test func parsesAllDigitsSentence() {
    #expect(
      PhoneticCallsignParser.parse("zero one two three four five six seven eight nine")
        == "0123456789")
  }

  @Test func unknownWordsFallBackToAlphanumericPassthrough() {
    #expect(PhoneticCallsignParser.parse("lufthansa 4 0 7") == "LUFTHANSA407")
  }

  @Test("should parse 600 generated spoken registrations to compact equality")
  func shouldParseGeneratedSpokenRegistrationsToCompactEquality() {
    let generatedCaseCount = 600
    var random = DeterministicParserRandom(seed: 0xD5_06_11_01)

    for _ in 0..<generatedCaseCount {
      let registration = Self.registration(random: &random)
      let spoken = registration.map { Self.spokenToken(for: $0, random: &random) }
        .joined(separator: " ")
      #expect(PhoneticCallsignParser.parse(spoken) == CallSign.normalize(registration))
    }

    print("PBT_CASE_COUNT phonetic-parser-roundtrip=600")
    #expect(generatedCaseCount == 600)
  }

  @Test("should parse 600 generated French spoken registrations to compact equality")
  func shouldParseGeneratedFrenchSpokenRegistrationsToCompactEquality() {
    let generatedCaseCount = 600
    var random = DeterministicParserRandom(seed: 0xD5_06_12_04)

    for _ in 0..<generatedCaseCount {
      let registration = Self.registration(random: &random)
      let spoken = registration.map { Self.frenchSpokenToken(for: $0, random: &random) }
        .joined(separator: " ")
      #expect(
        PhoneticCallsignParser.parse(spoken, localeIdentifier: "fr-FR")
          == CallSign.normalize(registration))
    }

    print("PBT_CASE_COUNT phonetic-parser-fr-roundtrip=600")
    #expect(generatedCaseCount == 600)
  }

  @Test("should reject 300 generated separator-only garbage strings")
  func shouldRejectGeneratedSeparatorOnlyGarbageStrings() {
    let generatedCaseCount = 300
    var random = DeterministicParserRandom(seed: 0xD5_06_11_02)

    for _ in 0..<generatedCaseCount {
      let garbage = Self.separatorGarbage(random: &random)
      #expect(PhoneticCallsignParser.parse(garbage).isEmpty)
    }

    print("PBT_CASE_COUNT phonetic-parser-garbage=300")
    #expect(generatedCaseCount == 300)
  }

  private struct DeterministicParserRandom {
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
  }

  private static let registrationPrefixes = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
  private static let registrationTailCharacters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
  private static let separatorCharacters = Array(" \n\t.,;:!?-_/()[]{}")

  private static func registration(random: inout DeterministicParserRandom) -> String {
    let prefix = registrationPrefixes[random.int(in: 0...(registrationPrefixes.count - 1))]
    let tailCount = random.int(in: 1...5)
    var result = String(prefix)
    for _ in 0..<tailCount {
      let next = registrationTailCharacters[
        random.int(in: 0...(registrationTailCharacters.count - 1))]
      result.append(next)
    }
    return result
  }

  private static func separatorGarbage(random: inout DeterministicParserRandom) -> String {
    let count = random.int(in: 1...64)
    var result = ""
    for _ in 0..<count {
      result.append(separatorCharacters[random.int(in: 0...(separatorCharacters.count - 1))])
    }
    return result
  }

  private static func spokenToken(
    for character: Character,
    random: inout DeterministicParserRandom
  ) -> String {
    let variants: [String]
    switch character {
    case "A": variants = ["Alpha", "Alfa"]
    case "B": variants = ["Bravo"]
    case "C": variants = ["Charlie"]
    case "D": variants = ["Delta"]
    case "E": variants = ["Echo"]
    case "F": variants = ["Foxtrot", "Fox"]
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
    case "X": variants = ["Xray", "X-ray", "Ex-ray", "X ray"]
    case "Y": variants = ["Yankee"]
    case "Z": variants = ["Zulu"]
    case "0": variants = ["Zero", "Oh"]
    case "1": variants = ["One", "Won"]
    case "2": variants = ["Two", "Too", "To"]
    case "3": variants = ["Three", "Tree"]
    case "4": variants = ["Four", "Fower", "For", "Fore"]
    case "5": variants = ["Five", "Fife"]
    case "6": variants = ["Six"]
    case "7": variants = ["Seven"]
    case "8": variants = ["Eight", "Ate"]
    case "9": variants = ["Nine", "Niner"]
    default: variants = [String(character)]
    }
    return variants[random.int(in: 0...(variants.count - 1))]
  }

  private static func frenchSpokenToken(
    for character: Character,
    random: inout DeterministicParserRandom
  ) -> String {
    let variants: [String]
    switch character {
    case "A": variants = ["Alpha", "Alfa"]
    case "B": variants = ["Bravo"]
    case "C": variants = ["Charlie"]
    case "D": variants = ["Delta"]
    case "E": variants = ["Echo"]
    case "F": variants = ["Foxtrot", "Fox"]
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
    case "X": variants = ["Xray", "X-ray", "Ex-ray", "X ray"]
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
}
