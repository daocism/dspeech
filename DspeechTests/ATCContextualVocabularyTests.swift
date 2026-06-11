import Foundation
import Testing

@testable import Dspeech

struct ATCContextualVocabularyTests {
  @Test func coversFullIcaoAlphabet() {
    #expect(ATCContextualVocabulary.icaoAlphabet.count == 26)
    #expect(ATCContextualVocabulary.icaoAlphabet.first == "Alpha")
    #expect(ATCContextualVocabulary.icaoAlphabet.last == "Zulu")
  }

  @Test func defaultStringsAreNonEmptyAndUnique() {
    let strings = ATCContextualVocabulary.strings()
    #expect(strings.allSatisfy { !$0.isEmpty })
    #expect(Set(strings).count == strings.count)
    #expect(
      strings.count == ATCContextualVocabulary.icaoAlphabet.count
        + ATCContextualVocabulary.digitWords.count
        + ATCContextualVocabulary.phraseology.count)
  }

  @Test func appendsNonEmptyCallSign() {
    let strings = ATCContextualVocabulary.strings(callSign: "N123AB")
    #expect(strings.contains("N123AB"))
  }

  @Test func appendsWrittenAndSpokenCallSignForms() {
    let strings = ATCContextualVocabulary.strings(callSign: "N123AB")
    #expect(strings.contains("N123AB"))
    #expect(strings.contains("November One Two Three Alpha Bravo"))
  }

  @Test func defaultStringsIncludeAviationDigitWords() {
    let strings = ATCContextualVocabulary.strings()
    #expect(strings.contains("Zero"))
    #expect(strings.contains("Niner"))
  }

  @Test func ignoresBlankCallSign() {
    let base = ATCContextualVocabulary.strings()
    #expect(ATCContextualVocabulary.strings(callSign: "") == base)
    #expect(ATCContextualVocabulary.strings(callSign: "   ") == base)
  }
}
