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
        localized: "Нет доступа к распознаванию речи. Разрешите его в Настройках iPhone.")
    }
    if rawCode == "microphone-permission-denied" {
      return String(localized: "Нет доступа к микрофону. Разрешите его в Настройках iPhone.")
    }
    if rawCode == "recognizer-unavailable" {
      return String(
        localized:
          "Этот язык недоступен для распознавания. Выберите другой язык в настройках распознавания."
      )
    }
    if rawCode == "recognition-locale-unavailable" {
      return String(
        localized:
          "Нет доступного локального языка распознавания. Откройте настройки распознавания и проверьте языки диктовки."
      )
    }
    if rawCode.hasPrefix("on-device-model-missing") {
      return String(
        localized:
          "Языковой пакет для распознавания не загружен. Включите диктовку и скачайте язык в Настройках → Основные → Клавиатура → Диктовка."
      )
    }
    if rawCode.hasPrefix("start-failed") {
      return String(
        localized: "Не удалось запустить распознавание. Проверьте микрофон и повторите попытку.")
    }
    if rawCode.hasPrefix("asr-error") {
      // why: kLSRErrorDomain#300 specifically means the on-device model could not run for
      // the chosen language — the exact symptom the user reported for a "downloaded" locale.
      if rawCode.contains("kLSRErrorDomain") && rawCode.contains("300") {
        return String(
          localized:
            "Локальная модель распознавания недоступна для этого языка. Скачайте языковой пакет для него или запустите на устройстве."
        )
      }
      if rawCode.contains("kAFAssistantErrorDomain") && rawCode.contains("1110") {
        return String(localized: "Речь не распознана — говорите ближе к микрофону.")
      }
      return String(localized: "Ошибка распознавания речи. Повторите попытку.")
    }
    // why: unknown code — still never echo the raw token to the screen.
    return String(localized: "Не удалось распознать речь. Повторите попытку.")
  }
}

enum TranslationFailureText {
  static func userFacing(_ failure: TranslationFailure) -> String {
    switch failure {
    case .emptyInput:
      return String(localized: "Нечего переводить: сегмент пустой.")
    case .sourceLanguageUnsupported:
      return String(
        localized:
          "Этот язык распознавания не поддерживается для локального перевода. Выберите другой язык распознавания."
      )
    case .targetLanguageUnsupported:
      return String(
        localized:
          "Целевой язык не поддерживается для локального перевода. Выберите другой язык перевода."
      )
    case .languagePairingUnsupported:
      return String(
        localized:
          "Эта языковая пара не поддерживается для локального перевода. Выберите другой целевой язык."
      )
    case .languagePackNotInstalled:
      return String(
        localized:
          "Языковой пакет перевода не установлен. Выключите и снова включите перевод — iOS предложит загрузку."
      )
    case .sessionCancelled, .preparationCancelled:
      return String(
        localized:
          "Подготовка локального перевода отменена. Включите перевод снова, если он нужен."
      )
    case .preparationFailed:
      return String(
        localized:
          "Не удалось подготовить локальный перевод. Проверьте языковой пакет и повторите попытку."
      )
    case .engineFailure:
      return String(localized: "Системный перевод не выполнился. Повторите попытку.")
    }
  }
}
