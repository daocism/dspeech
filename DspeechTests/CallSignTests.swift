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

  @Test func everydayNineSpellingMatches() throws {
    // the recognizer emits "nine", not the ICAO "niner"
    let cs = try #require(CallSign(raw: "N9A"))
    #expect(cs.matches(in: "November Nine Alpha contact tower"))
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
}
