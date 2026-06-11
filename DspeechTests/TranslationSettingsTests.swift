import Foundation
import Testing

@testable import Dspeech

@MainActor
struct TranslationSettingsTests {
  enum TestError: Error {
    case saveFailed
  }

  final class InMemoryStorage: TranslationSettingsStorage, @unchecked Sendable {
    var enabled: Bool?
    var targetCode: String?
    var failSaves = false
    func loadEnabled() -> Bool { enabled ?? false }
    func saveEnabled(_ value: Bool) throws {
      if failSaves { throw TestError.saveFailed }
      enabled = value
    }
    func loadTargetCode() -> String? { targetCode }
    func saveTargetCode(_ code: String) throws {
      if failSaves { throw TestError.saveFailed }
      targetCode = code
    }
  }

  @Test func defaultsToDisabled() {
    let settings = TranslationSettings(storage: InMemoryStorage(), preferredLanguages: ["ru-RU"])
    #expect(settings.enabled == false)
  }

  @Test func resolvesTargetDifferentFromDefaultRecognitionLanguage() {
    let settings = TranslationSettings(
      storage: InMemoryStorage(), preferredLanguages: ["ru-RU", "en-US"],
      sourceLanguageCode: "ru")
    #expect(settings.targetCode == "en")
    #expect(settings.targetLanguage.languageCode?.identifier == "en")
  }

  @Test func resolvesDeviceLanguageWhenDifferentFromSource() {
    let settings = TranslationSettings(
      storage: InMemoryStorage(), preferredLanguages: ["es-ES", "en-US"],
      sourceLanguageCode: "fr")
    #expect(settings.targetCode == "es")
  }

  @Test func fallsBackToEnglishWhenPreferredUnsupported() {
    let settings = TranslationSettings(
      storage: InMemoryStorage(), preferredLanguages: ["xx-YY"], sourceLanguageCode: "fr")
    #expect(settings.targetCode == "en")
  }

  @Test func enableAndTargetPersist() {
    let storage = InMemoryStorage()
    let settings = TranslationSettings(
      storage: storage, preferredLanguages: ["en-US"], sourceLanguageCode: "fr")

    settings.enabled = true
    settings.targetCode = "uk"

    #expect(storage.enabled == true)
    #expect(storage.targetCode == "uk")
  }

  @Test func resolveIgnoresStoredUnsupportedCode() {
    let storage = InMemoryStorage()
    storage.targetCode = "zz"
    let settings = TranslationSettings(
      storage: storage, preferredLanguages: ["fr-FR"], sourceLanguageCode: "de")
    #expect(settings.targetCode == "fr")
    #expect(settings.storageIssue == .translationTargetCorrupted)
  }

  @Test func enablingRepairsSameLanguageTargetBeforePersisting() {
    let storage = InMemoryStorage()
    storage.targetCode = "fr"
    let settings = TranslationSettings(
      storage: storage, preferredLanguages: ["fr-FR", "en-US"], sourceLanguageCode: "fr")

    settings.enabled = true

    #expect(settings.targetCode == "en")
    #expect(storage.targetCode == "en")
    #expect(storage.enabled == true)
    #expect(settings.storageIssue == nil)
  }

  @Test func enabledStoredSameLanguageTargetRepairsOnInit() {
    let storage = InMemoryStorage()
    storage.enabled = true
    storage.targetCode = "fr"

    let settings = TranslationSettings(
      storage: storage, preferredLanguages: ["fr-FR", "en-US"], sourceLanguageCode: "fr")

    #expect(settings.enabled)
    #expect(settings.targetCode == "en")
    #expect(storage.targetCode == "en")
    #expect(settings.storageIssue == nil)
  }

  @Test func saveFailureSurfacesStaleSettingsIssue() {
    let storage = InMemoryStorage()
    storage.failSaves = true
    let settings = TranslationSettings(
      storage: storage, preferredLanguages: ["fr-FR"], sourceLanguageCode: "de")

    settings.enabled = true

    #expect(settings.enabled)
    #expect(storage.enabled == nil)
    #expect(settings.storageIssue == .translationEnabledSaveFailed)
    #expect(settings.hasStaleSettings)
  }

  @Test func catalogIsSortedAndCoversCommonLanguages() {
    let options = TranslationLanguageCatalog.options(displayLocale: Locale(identifier: "en"))
    let codes = Set(options.map(\.code))
    #expect(codes.contains("ru"))
    #expect(codes.contains("en"))
    #expect(codes.contains("uk"))
    let names = options.map(\.displayName)
    #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
  }

  @Test func userDefaultsRoundTrip() throws {
    let suiteName = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storage = UserDefaultsTranslationSettingsStorage(defaults: defaults)

    #expect(storage.loadEnabled() == false)
    try storage.saveEnabled(true)
    #expect(storage.loadEnabled() == true)

    #expect(storage.loadTargetCode() == nil)
    try storage.saveTargetCode("ja")
    #expect(storage.loadTargetCode() == "ja")
  }

  @Test func userDefaultsInvalidEnabledStringFallsBackOffAndSurfacesIssue() {
    let suiteName = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storage = UserDefaultsTranslationSettingsStorage(defaults: defaults)

    defaults.set("maybe", forKey: UserDefaultsTranslationSettingsStorage.enabledKey)

    #expect(storage.loadEnabled() == false)
    #expect(storage.loadIssue() == .translationEnabledCorrupted)
  }
}
