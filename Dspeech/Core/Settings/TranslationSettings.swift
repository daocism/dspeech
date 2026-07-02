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
    defaultTargetCode(preferredLanguages: preferredLanguages, sourceLanguageCode: nil)
  }

  static func defaultTargetCode(
    preferredLanguages: [String] = Locale.preferredLanguages,
    sourceLanguageCode: String?
  ) -> String {
    let source = sourceLanguageCode?.lowercased()
    for preferred in preferredLanguages {
      if let code = Locale(identifier: preferred).language.languageCode?.identifier,
        supportedCodes.contains(code),
        code.lowercased() != source
      {
        return code
      }
    }
    if source != "en" { return "en" }
    return supportedCodes.first { $0.lowercased() != source } ?? "en"
  }

  static func resolve(
    stored: String?,
    preferredLanguages: [String] = Locale.preferredLanguages,
    sourceLanguageCode: String? = nil
  ) -> String {
    if let stored, supportedCodes.contains(stored) { return stored }
    return defaultTargetCode(
      preferredLanguages: preferredLanguages,
      sourceLanguageCode: sourceLanguageCode)
  }

  static func defaultSourceLanguageCode(preferredLanguages: [String]) -> String? {
    preferredLanguages.compactMap {
      Locale(identifier: $0).language.languageCode?.identifier
    }.first
  }
}

protocol TranslationSettingsStorage: Sendable {
  func loadEnabled() -> Bool
  func saveEnabled(_ enabled: Bool) throws
  func loadTargetCode() -> String?
  func saveTargetCode(_ code: String) throws
  func loadIssue() -> SettingsStorageIssue?
}

extension TranslationSettingsStorage {
  func loadIssue() -> SettingsStorageIssue? { nil }
}

struct UserDefaultsTranslationSettingsStorage: TranslationSettingsStorage, @unchecked Sendable {
  static let enabledKey = "dspeech.translation.enabled.v1"
  static let targetKey = "dspeech.translation.target.v1"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func loadEnabled() -> Bool {
    if let enabled = defaults.object(forKey: Self.enabledKey) as? Bool { return enabled }
    if let raw = defaults.string(forKey: Self.enabledKey) {
      return SettingsBoolParsing.parse(raw) ?? false
    }
    return false
  }

  func saveEnabled(_ enabled: Bool) throws { defaults.set(enabled, forKey: Self.enabledKey) }
  func loadTargetCode() -> String? { defaults.string(forKey: Self.targetKey) }
  func saveTargetCode(_ code: String) throws { defaults.set(code, forKey: Self.targetKey) }

  func loadIssue() -> SettingsStorageIssue? {
    let rawEnabled = defaults.object(forKey: Self.enabledKey)
    if rawEnabled != nil, !(rawEnabled is Bool) {
      if let raw = rawEnabled as? String, SettingsBoolParsing.parse(raw) != nil {
      } else {
        return .translationEnabledCorrupted
      }
    }
    if let target = defaults.string(forKey: Self.targetKey),
      !TranslationLanguageCatalog.supportedCodes.contains(target)
    {
      return .translationTargetCorrupted
    }
    return nil
  }
}

@MainActor
@Observable
final class TranslationSettings {
  private let storage: TranslationSettingsStorage
  private let sourceLanguageCode: String?
  private let preferredLanguages: [String]
  let availableTargets: [TranslationLanguageOption]
  private(set) var storageIssue: SettingsStorageIssue?
  var hasStaleSettings: Bool { storageIssue != nil }

  var enabled: Bool {
    didSet {
      guard enabled != oldValue else { return }
      if enabled { ensureTargetDiffersFromSource() }
      do {
        try storage.saveEnabled(enabled)
        storageIssue = nil
      } catch {
        storageIssue = .translationEnabledSaveFailed
      }
    }
  }

  var targetCode: String {
    didSet {
      guard targetCode != oldValue else { return }
      persistTargetCode(targetCode)
    }
  }

  var targetLanguage: Locale.Language { Locale.Language(identifier: targetCode) }

  init(
    storage: TranslationSettingsStorage = UserDefaultsTranslationSettingsStorage(),
    availableTargets: [TranslationLanguageOption] = TranslationLanguageCatalog.options(),
    preferredLanguages: [String] = Locale.preferredLanguages,
    sourceLanguageCode: String? = nil
  ) {
    self.storage = storage
    self.sourceLanguageCode =
      sourceLanguageCode
      ?? TranslationLanguageCatalog.defaultSourceLanguageCode(
        preferredLanguages: preferredLanguages)
    self.preferredLanguages = preferredLanguages
    self.availableTargets = availableTargets
    self.enabled = storage.loadEnabled()
    let storedTarget = storage.loadTargetCode()
    self.targetCode = TranslationLanguageCatalog.resolve(
      stored: storedTarget,
      preferredLanguages: preferredLanguages,
      sourceLanguageCode: self.sourceLanguageCode
    )
    if let issue = storage.loadIssue() {
      self.storageIssue = issue
    } else if let storedTarget, !TranslationLanguageCatalog.supportedCodes.contains(storedTarget) {
      self.storageIssue = .translationTargetCorrupted
    }
    if enabled {
      let previousTargetCode = targetCode
      ensureTargetDiffersFromSource()
      if targetCode != previousTargetCode {
        persistTargetCode(targetCode)
      }
    }
  }

  private func ensureTargetDiffersFromSource() {
    guard let sourceLanguageCode,
      targetCode.lowercased() == sourceLanguageCode.lowercased()
    else { return }
    targetCode = TranslationLanguageCatalog.defaultTargetCode(
      preferredLanguages: preferredLanguages,
      sourceLanguageCode: sourceLanguageCode)
  }

  private func persistTargetCode(_ code: String) {
    do {
      try storage.saveTargetCode(code)
      storageIssue = nil
    } catch {
      storageIssue = .translationTargetSaveFailed
    }
  }
}
