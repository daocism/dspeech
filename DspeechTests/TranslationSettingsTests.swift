import Foundation
import Testing

@testable import Dspeech

@MainActor
struct TranslationSettingsTests {
  final class InMemoryStorage: TranslationSettingsStorage, @unchecked Sendable {
    var enabled: Bool?
    var targetCode: String?
    func loadEnabled() -> Bool { enabled ?? false }
    func saveEnabled(_ value: Bool) { enabled = value }
    func loadTargetCode() -> String? { targetCode }
    func saveTargetCode(_ code: String) { targetCode = code }
  }

  @Test func defaultsToDisabled() {
    let settings = TranslationSettings(storage: InMemoryStorage(), preferredLanguages: ["ru-RU"])
    #expect(settings.enabled == false)
  }

  @Test func resolvesTargetFromPreferredLanguages() {
    let settings = TranslationSettings(
      storage: InMemoryStorage(), preferredLanguages: ["ru-RU", "en-US"])
    #expect(settings.targetCode == "ru")
    #expect(settings.targetLanguage.languageCode?.identifier == "ru")
  }

  @Test func fallsBackToEnglishWhenPreferredUnsupported() {
    let settings = TranslationSettings(storage: InMemoryStorage(), preferredLanguages: ["xx-YY"])
    #expect(settings.targetCode == "en")
  }

  @Test func enableAndTargetPersist() {
    let storage = InMemoryStorage()
    let settings = TranslationSettings(storage: storage, preferredLanguages: ["en-US"])

    settings.enabled = true
    settings.targetCode = "uk"

    #expect(storage.enabled == true)
    #expect(storage.targetCode == "uk")
  }

  @Test func resolveIgnoresStoredUnsupportedCode() {
    let storage = InMemoryStorage()
    storage.targetCode = "zz"
    let settings = TranslationSettings(storage: storage, preferredLanguages: ["fr-FR"])
    #expect(settings.targetCode == "fr")
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

  @Test func userDefaultsRoundTrip() {
    let suiteName = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storage = UserDefaultsTranslationSettingsStorage(defaults: defaults)

    #expect(storage.loadEnabled() == false)
    storage.saveEnabled(true)
    #expect(storage.loadEnabled() == true)

    #expect(storage.loadTargetCode() == nil)
    storage.saveTargetCode("ja")
    #expect(storage.loadTargetCode() == "ja")
  }
}
