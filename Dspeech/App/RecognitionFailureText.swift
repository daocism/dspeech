import Foundation

// why: the live engine emits terse, machine-stable failure codes (recognizer-unavailable,
// on-device-model-missing, asr-error: <domain>#<code>, …). Those are correct for logs and
// tests but must never reach a pilot's screen verbatim. This pure mapper is the single
// boundary that turns a code into one actionable localized sentence; it is exhaustively
// unit-tested so a new code can't silently leak raw (the "Ошибка: kLSRErrorDomain#300"
// the user hit).
enum RecognitionFailureText {
  static func userFacing(_ rawCode: String) -> String {
    if rawCode == "speech-permission-denied" {
      return String(
        localized: "No speech recognition access. Allow it in iPhone Settings.")
    }
    if rawCode == "microphone-permission-denied" {
      return String(localized: "No microphone access. Allow it in iPhone Settings.")
    }
    if rawCode == "permission-request-timed-out" {
      return String(
        localized:
          "Couldn't get microphone and speech access. Check the permissions in iPhone Settings, then tap Start again."
      )
    }
    if rawCode == "recognizer-unavailable" {
      return String(
        localized:
          "This language isn't available for recognition. Choose another language in recognition settings."
      )
    }
    if rawCode == "recognition-locale-unavailable" {
      return String(
        localized:
          "No on-device recognition language available. Open recognition settings and check your dictation languages."
      )
    }
    if rawCode.hasPrefix("on-device-model-missing") {
      return String(
        localized:
          "The recognition language pack isn't downloaded. Turn on Dictation and download the language in Settings → General → Keyboard → Dictation."
      )
    }
    if rawCode.hasPrefix("start-failed") {
      return String(
        localized: "Couldn't start recognition. Check the microphone and try again.")
    }
    if rawCode.hasPrefix("engine-configuration-change-failed") {
      return String(
        localized:
          "Audio input changed and recognition couldn't recover. Check the input and start again.")
    }
    if rawCode == "engine-died-before-restart" {
      return String(
        localized: "Audio input stopped unexpectedly. Check the input and start again.")
    }
    if rawCode == "capture-session-busy" {
      return String(
        localized:
          "Another recording task is using the microphone. Stop it before starting live transcription."
      )
    }
    if rawCode.hasPrefix("audio-session-deactivation-failed") {
      return String(
        localized:
          "Audio capture stopped, but iOS couldn't release the audio session. Check the input before starting again."
      )
    }
    if rawCode.hasPrefix("asr-error") {
      // why: kLSRErrorDomain#300 specifically means the on-device model could not run for
      // the chosen language — the exact symptom the user reported for a "downloaded" locale.
      if rawCode.contains("kLSRErrorDomain") && rawCode.contains("300") {
        return String(
          localized:
            "No on-device recognition model is available for this language. Download its language pack or run it on-device."
        )
      }
      if rawCode.contains("kAFAssistantErrorDomain") && rawCode.contains("1110") {
        return String(localized: "No speech recognized — speak closer to the microphone.")
      }
      return String(localized: "Speech recognition error. Try again.")
    }
    // why: unknown code — still never echo the raw token to the screen.
    return String(localized: "Couldn't recognize speech. Try again.")
  }
}

enum TranslationFailureText {
  static func userFacing(_ failure: TranslationFailure) -> String {
    switch failure {
    case .emptyInput:
      return String(localized: "Nothing to translate: the segment is empty.")
    case .sourceLanguageUnsupported:
      return String(
        localized:
          "This recognition language isn't supported for on-device translation. Choose another recognition language."
      )
    case .targetLanguageUnsupported:
      return String(
        localized:
          "The target language isn't supported for on-device translation. Choose another translation language."
      )
    case .languagePairingUnsupported:
      return String(
        localized:
          "This language pair isn't supported for on-device translation. Choose another target language."
      )
    case .languagePackNotInstalled:
      return String(
        localized:
          "The translation language pack isn't installed. Turn translation off and on again — iOS will offer the download."
      )
    case .sessionCancelled, .preparationCancelled:
      return String(
        localized:
          "On-device translation setup was canceled. Turn translation on again if you need it."
      )
    case .preparationFailed:
      return String(
        localized:
          "Couldn't prepare on-device translation. Check the language pack and try again."
      )
    case .engineFailure:
      return String(localized: "System translation failed. Try again.")
    }
  }
}
