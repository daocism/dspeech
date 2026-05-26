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

    @Test func noMatchInUnrelatedText() throws {
        let cs = try #require(CallSign(raw: "N123AB"))
        #expect(cs.matches(in: "United 247 contact ground point niner") == false)
    }
}
