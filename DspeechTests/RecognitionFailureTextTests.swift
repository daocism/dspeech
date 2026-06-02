import Foundation
import Testing

@testable import Dspeech

// why: this is the guard that the user's "Ошибка: recognizer-unavailable" /
// "asr-error:kLSRErrorDomain#300" can never reach the screen as a raw code again. It runs
// on the Simulator (pure logic) and covers every code the engine emits.
struct RecognitionFailureTextTests {

  // Every terse code the engine can put into .failed(...).
  private static let allEngineCodes: [String] = [
    "speech-permission-denied",
    "microphone-permission-denied",
    "recognizer-unavailable",
    "on-device-model-missing: en-US",
    "on-device-model-missing: fr-FR",
    "start-failed: The operation couldn’t be completed.",
    "asr-error: kLSRErrorDomain#300 The operation couldn’t be completed.",
    "asr-error: kAFAssistantErrorDomain#1110 No speech detected.",
    "asr-error: kAFAssistantErrorDomain#203 Retry.",
  ]

  // Raw machine tokens that must NEVER appear in user-facing text.
  private static let forbiddenTokens = [
    "kLSRErrorDomain", "kAFAssistantErrorDomain", "recognizer-unavailable",
    "on-device-model-missing", "asr-error", "start-failed", "#300", "#1110", "#203",
  ]

  @Test(arguments: allEngineCodes)
  func everyCodeMapsToNonEmptyHumanTextWithNoRawTokenLeak(code: String) {
    let text = RecognitionFailureText.userFacing(code)
    #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    for token in Self.forbiddenTokens {
      #expect(
        !text.contains(token),
        "user-facing text leaked raw token \(token) for code \(code): \(text)")
    }
  }

  @Test func unknownCodeStillProducesHumanTextNotTheRawCode() {
    let text = RecognitionFailureText.userFacing("totally-unknown-future-code-42")
    #expect(!text.isEmpty)
    #expect(!text.contains("totally-unknown-future-code-42"))
  }

  // The user's two exact symptoms get DISTINCT, actionable messages (not the generic one).
  @Test func unavailableLocaleAndOnDeviceModelGetDistinctActionableMessages() {
    let unavailable = RecognitionFailureText.userFacing("recognizer-unavailable")
    let lsr300 = RecognitionFailureText.userFacing(
      "asr-error: kLSRErrorDomain#300 The operation couldn’t be completed.")
    let generic = RecognitionFailureText.userFacing("asr-error: SomeOther#9 boom")
    #expect(unavailable != lsr300)
    #expect(lsr300 != generic)
    #expect(unavailable != generic)
  }

  @Test func permissionCodesAreDistinguished() {
    let mic = RecognitionFailureText.userFacing("microphone-permission-denied")
    let speech = RecognitionFailureText.userFacing("speech-permission-denied")
    #expect(mic != speech)
    #expect(!mic.isEmpty && !speech.isEmpty)
  }
}
