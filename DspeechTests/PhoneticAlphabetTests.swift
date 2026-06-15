import Testing

@testable import Dspeech

// Pins the extracted single source of truth (PhoneticAlphabet) and proves BOTH decoders stay
// consistent with it. Behavior preservation of the extraction itself is covered by the existing
// CallSignTests / PhoneticCallsignParserTests property suites; these guard the canonical alphabet
// against future drift in either consumer.
struct PhoneticAlphabetTests {
  @Test func icaoAlphabetCoversEveryLetterAndDigitWithDistinctUppercaseWords() {
    let expectedKeys = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    #expect(Set(PhoneticAlphabet.icao.keys) == expectedKeys)
    // distinct spoken words (no two symbols share a word)
    #expect(Set(PhoneticAlphabet.icao.values).count == PhoneticAlphabet.icao.count)
    #expect(PhoneticAlphabet.icao.values.allSatisfy { !$0.isEmpty && $0 == $0.uppercased() })
  }

  // Every canonical ICAO word must parse back to its letter/digit on the enrollment path.
  @Test func parserDecodesEveryCanonicalIcaoWord() {
    for (character, word) in PhoneticAlphabet.icao {
      #expect(PhoneticCallsignParser.parse(word.lowercased()) == String(character))
    }
  }

  // Every canonical ICAO word must decode to its letter/digit on the ATC-transcript matching path.
  @Test func callSignMatchesEveryCanonicalIcaoWord() {
    for (character, word) in PhoneticAlphabet.icao {
      let sign = CallSign(raw: String(character))
      #expect(sign?.matches(in: word) == true)
    }
  }

  @Test func frenchDigitsAndIgnoredTokensAreUppercaseAndCoverZeroThroughNine() {
    #expect(
      Set(PhoneticAlphabet.frenchDigits.values)
        == Set(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]))
    #expect(PhoneticAlphabet.frenchDigits.keys.allSatisfy { $0 == $0.uppercased() })
    #expect(PhoneticAlphabet.frenchIgnoredTokens.allSatisfy { $0 == $0.uppercased() })
  }
}
