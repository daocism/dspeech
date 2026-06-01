import Foundation
import Testing

@testable import Dspeech

struct RecognitionSettingsTests {
  private let supported: Set<Locale> = [
    Locale(identifier: "en-US"),
    Locale(identifier: "fr-FR"),
    Locale(identifier: "de-DE"),
  ]
  private var enUS: String { Locale(identifier: "en-US").identifier }
  private var frFR: String { Locale(identifier: "fr-FR").identifier }
  private var deDE: String { Locale(identifier: "de-DE").identifier }

  @Test func resolveKeepsStoredIdentifierWhenSupported() {
    let resolved = RecognitionLocaleCatalog.resolve(
      stored: frFR, supported: supported, preferredLanguages: ["en-US"])
    #expect(resolved == frFR)
  }

  @Test func resolveFallsBackToPreferredLanguageWhenStoredUnsupported() {
    let resolved = RecognitionLocaleCatalog.resolve(
      stored: "es-ES", supported: supported, preferredLanguages: ["fr-FR", "en-US"])
    #expect(resolved == frFR)
  }

  @Test func resolveMatchesPreferredByLanguageCodeIgnoringRegion() {
    let resolved = RecognitionLocaleCatalog.resolve(
      stored: nil, supported: supported, preferredLanguages: ["fr-CA"])
    #expect(resolved == frFR)
  }

  @Test func resolveFallsBackToEnglishWhenNoPreferredMatch() {
    let resolved = RecognitionLocaleCatalog.resolve(
      stored: nil, supported: supported, preferredLanguages: ["ja-JP"])
    #expect(resolved == enUS)
  }

  @Test func resolveFallsBackToFirstSortedWhenNoEnglishAndNoMatch() {
    let onlyNonEnglish: Set<Locale> = [Locale(identifier: "fr-FR"), Locale(identifier: "de-DE")]
    let resolved = RecognitionLocaleCatalog.resolve(
      stored: nil, supported: onlyNonEnglish, preferredLanguages: ["ja-JP"])
    #expect([frFR, deDE].contains(resolved))
  }

  @Test func sortedLocalesMapIdentifiersAndSortByDisplayName() {
    let locales = RecognitionLocaleCatalog.sortedLocales(
      supported: supported, displayLocale: Locale(identifier: "en-US"))
    #expect(locales.count == 3)
    #expect(Set(locales.map(\.identifier)) == [enUS, frFR, deDE])
    let names = locales.map(\.displayName)
    #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
  }

  @MainActor @Test func settingsPersistSelectionAndReload() {
    let storage = InMemoryRecognitionSettingsStorage()
    let settings = RecognitionSettings(
      storage: storage, supportedLocales: supported, preferredLanguages: ["en-US"])
    #expect(settings.localeIdentifier == enUS)
    settings.localeIdentifier = frFR
    #expect(storage.stored == frFR)
    let reloaded = RecognitionSettings(
      storage: storage, supportedLocales: supported, preferredLanguages: ["en-US"])
    #expect(reloaded.localeIdentifier == frFR)
  }

  @MainActor @Test func settingsIgnoreUnsupportedStoredValueOnLoad() {
    let storage = InMemoryRecognitionSettingsStorage()
    storage.stored = "ru-RU"
    let settings = RecognitionSettings(
      storage: storage, supportedLocales: supported, preferredLanguages: ["de-DE"])
    #expect(settings.localeIdentifier == deDE)
  }
}

private final class InMemoryRecognitionSettingsStorage: RecognitionSettingsStorage,
  @unchecked Sendable
{
  var stored: String?
  func loadLocaleIdentifier() -> String? { stored }
  func saveLocaleIdentifier(_ identifier: String) { stored = identifier }
}
