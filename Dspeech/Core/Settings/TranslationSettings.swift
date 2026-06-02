import Foundation
import Observation

struct TranslationLanguageOption: Identifiable, Equatable, Sendable {
  let code: String
  let displayName: String
  var id: String { code }
}

enum TranslationLanguageCatalog {
  // why: bounds what the target picker offers; the actually-installable set is
  // device-decided at runtime via LanguageAvailability, not by this list.
  static let supportedCodes = [
    "ar", "de", "en", "es", "fr", "hi", "id", "it", "ja", "ko",
    "nl", "pl", "pt", "ru", "th", "tr", "uk", "vi", "zh",
  ]

  static func options(displayLocale: Locale = .current) -> [TranslationLanguageOption] {
    supportedCodes
      .map { code in
        TranslationLanguageOption(
          code: code,
          displayName: displayLocale.localizedString(forLanguageCode: code) ?? code
        )
      }
      .sorted {
        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      }
  }

  static func defaultTargetCode(preferredLanguages: [String] = Locale.preferredLanguages) -> String
  {
    for preferred in preferredLanguages {
      if let code = Locale(identifier: preferred).language.languageCode?.identifier,
        supportedCodes.contains(code)
      {
        return code
      }
    }
    return "en"
  }

  static func resolve(
    stored: String?,
    preferredLanguages: [String] = Locale.preferredLanguages
  ) -> String {
    if let stored, supportedCodes.contains(stored) { return stored }
    return defaultTargetCode(preferredLanguages: preferredLanguages)
  }
}

protocol TranslationSettingsStorage: Sendable {
  func loadEnabled() -> Bool
  func saveEnabled(_ enabled: Bool)
  func loadTargetCode() -> String?
  func saveTargetCode(_ code: String)
}

struct UserDefaultsTranslationSettingsStorage: TranslationSettingsStorage, @unchecked Sendable {
  static let enabledKey = "dspeech.translation.enabled.v1"
  static let targetKey = "dspeech.translation.target.v1"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  // why: unset resolves to false (off by default per PRD) and a launch-argument
  // "true"/"false" string resolves via NSString boolValue — both via bool(forKey:).
  func loadEnabled() -> Bool { defaults.bool(forKey: Self.enabledKey) }
  func saveEnabled(_ enabled: Bool) { defaults.set(enabled, forKey: Self.enabledKey) }
  func loadTargetCode() -> String? { defaults.string(forKey: Self.targetKey) }
  func saveTargetCode(_ code: String) { defaults.set(code, forKey: Self.targetKey) }
}

@MainActor
@Observable
final class TranslationSettings {
  private let storage: TranslationSettingsStorage
  let availableTargets: [TranslationLanguageOption]

  var enabled: Bool {
    didSet {
      guard enabled != oldValue else { return }
      storage.saveEnabled(enabled)
    }
  }

  var targetCode: String {
    didSet {
      guard targetCode != oldValue else { return }
      storage.saveTargetCode(targetCode)
    }
  }

  var targetLanguage: Locale.Language { Locale.Language(identifier: targetCode) }

  init(
    storage: TranslationSettingsStorage = UserDefaultsTranslationSettingsStorage(),
    availableTargets: [TranslationLanguageOption] = TranslationLanguageCatalog.options(),
    preferredLanguages: [String] = Locale.preferredLanguages
  ) {
    self.storage = storage
    self.availableTargets = availableTargets
    self.enabled = storage.loadEnabled()
    self.targetCode = TranslationLanguageCatalog.resolve(
      stored: storage.loadTargetCode(),
      preferredLanguages: preferredLanguages
    )
  }
}
