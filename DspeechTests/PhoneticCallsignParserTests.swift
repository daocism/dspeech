import Foundation
import Testing

@testable import Dspeech

struct PhoneticCallsignParserTests {
  @Test func parsesFullPhoneticTailNumber() {
    #expect(PhoneticCallsignParser.parse("november one two three alpha bravo") == "N123AB")
  }

  @Test func parsesAviationDigitVariants() {
    #expect(PhoneticCallsignParser.parse("tree fife niner") == "359")
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

  @Test func emptyInputYieldsEmpty() {
    #expect(PhoneticCallsignParser.parse("   ") == "")
  }

  @Test func resultFeedsCallSignParser() {
    let parsed = PhoneticCallsignParser.parse("romeo alpha eight nine zero seven seven")
    let callsign = CallSign(raw: parsed)
    #expect(callsign?.normalized == "RA89077")
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
    ("zero", "0"), ("oh", "0"), ("one", "1"), ("won", "1"), ("two", "2"), ("too", "2"),
    ("to", "2"), ("three", "3"), ("tree", "3"), ("four", "4"), ("for", "4"), ("fore", "4"),
    ("five", "5"), ("fife", "5"), ("six", "6"), ("seven", "7"), ("eight", "8"), ("ate", "8"),
    ("nine", "9"), ("niner", "9"),
  ])
  func parsesEveryIcaoTokenVariant(_ pair: (spoken: String, expected: String)) {
    #expect(PhoneticCallsignParser.parse(pair.spoken) == pair.expected)
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
}
