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
}
