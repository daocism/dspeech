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

  // The user's request: the default ALWAYS follows the device language when supported,
  // never silently English. Russian device + supported ru-RU -> ru-RU, not en-US.
  @Test func defaultsToDeviceLanguageWhenSupported() {
    let supported: Set<Locale> = [
      Locale(identifier: "en-US"), Locale(identifier: "ru-RU"), Locale(identifier: "fr-FR"),
    ]
    let resolved = RecognitionLocaleCatalog.resolve(
      stored: nil, supported: supported, preferredLanguages: ["ru-RU", "en-US"])
    #expect(resolved == Locale(identifier: "ru-RU").identifier)
  }

  // Device-language match is deterministic and prefers the device's exact region.
  @Test func defaultPrefersDeviceRegionAmongSameLanguageVariants() {
    let supported: Set<Locale> = [
      Locale(identifier: "en-US"), Locale(identifier: "en-GB"), Locale(identifier: "en-AU"),
    ]
    let resolved = RecognitionLocaleCatalog.defaultIdentifier(
      supported: supported, preferredLanguages: ["en-GB"])
    #expect(resolved == Locale(identifier: "en-GB").identifier)
  }

  // Device language with a different region still resolves to that language (not English).
  @Test func defaultMatchesDeviceLanguageEvenWhenRegionDiffers() {
    let supported: Set<Locale> = [Locale(identifier: "en-US"), Locale(identifier: "ru-RU")]
    let resolved = RecognitionLocaleCatalog.defaultIdentifier(
      supported: supported, preferredLanguages: ["ru-KZ"])
    #expect(resolved == Locale(identifier: "ru-RU").identifier)
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
