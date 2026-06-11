import Foundation
import Testing

@testable import Dspeech

struct RecognitionSettingsTests {
  enum TestError: Error {
    case saveFailed
  }

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
    #expect(resolved == frFR || resolved == deDE)
  }

  @Test func resolveReturnsNilWhenSupportedSetIsEmpty() {
    let resolved = RecognitionLocaleCatalog.resolve(
      stored: enUS, supported: [], preferredLanguages: ["en-US"])
    #expect(resolved == nil)
  }

  @Test func onDeviceResolverDoesNotFallbackToRecognizerLocalesWhenOnDeviceSetIsEmpty() {
    let capable = OnDeviceLocaleResolver.capableLocales(
      recognizerSupported: supported,
      onDeviceSupported: []
    )
    #expect(capable.isEmpty)
  }

  @Test func onDeviceResolverFallsBackToOnDeviceSetWhenIntersectionIsEmpty() {
    let onDeviceOnly: Set<Locale> = [Locale(identifier: "it-IT")]
    let capable = OnDeviceLocaleResolver.capableLocales(
      recognizerSupported: [Locale(identifier: "en-US")],
      onDeviceSupported: onDeviceOnly
    )
    #expect(capable == onDeviceOnly)
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
    #expect(settings.activeLocaleIdentifier == nil)
    settings.localeIdentifier = frFR
    #expect(storage.stored == frFR)
    let reloaded = RecognitionSettings(
      storage: storage, supportedLocales: supported, preferredLanguages: ["en-US"])
    #expect(reloaded.localeIdentifier == frFR)
  }

  @MainActor @Test func engineChoiceDefaultsToApple() {
    let settings = RecognitionSettings(
      storage: InMemoryRecognitionSettingsStorage(),
      supportedLocales: supported,
      preferredLanguages: ["en-US"])

    #expect(settings.engineChoice == .apple)
  }

  @MainActor @Test func engineChoicePersistsWhisperKitAndReloads() {
    let storage = InMemoryRecognitionSettingsStorage()
    let settings = RecognitionSettings(
      storage: storage,
      supportedLocales: supported,
      preferredLanguages: ["en-US"])

    settings.engineChoice = .whisperKit

    #expect(storage.engineChoice == .whisperKit)
    let reloaded = RecognitionSettings(
      storage: storage,
      supportedLocales: supported,
      preferredLanguages: ["en-US"])
    #expect(reloaded.engineChoice == .whisperKit)
  }

  @Test func userDefaultsEngineChoiceRoundTrip() throws {
    let suiteName = "dspeech.tests.recognition.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storage = UserDefaultsRecognitionSettingsStorage(defaults: defaults)

    #expect(storage.loadEngineChoice() == .apple)
    try storage.saveEngineChoice(.whisperKit)
    #expect(storage.loadEngineChoice() == .whisperKit)
    try storage.saveEngineChoice(.apple)
    #expect(storage.loadEngineChoice() == .apple)
  }

  @MainActor @Test func settingsIgnoreUnsupportedStoredValueOnLoad() {
    let storage = InMemoryRecognitionSettingsStorage()
    storage.stored = "ru-RU"
    let settings = RecognitionSettings(
      storage: storage, supportedLocales: supported, preferredLanguages: ["de-DE"])
    #expect(settings.localeIdentifier == deDE)
  }

  // The picker must show ONLY on-device-capable languages after refresh.
  @MainActor @Test func refreshNarrowsAvailableLocalesToCapable() async {
    let settings = RecognitionSettings(
      storage: InMemoryRecognitionSettingsStorage(), supportedLocales: supported,
      preferredLanguages: ["en-US"],
      availability: FakeAvailability(
        capable: [Locale(identifier: "en-US"), Locale(identifier: "fr-FR")], downloaded: [enUS]))
    await settings.refreshCapableLocales()
    #expect(Set(settings.availableLocales.map(\.identifier)) == [enUS, frFR])
    #expect(settings.localeAvailabilityState == .available)
    #expect(settings.activeLocaleIdentifier == enUS)
  }

  // why: a transient capable-set narrowing must not overwrite the user's stored locale.
  @MainActor @Test func refreshKeepsStoredLocaleWhenCapableSetNarrows() async {
    let storage = InMemoryRecognitionSettingsStorage()
    storage.stored = deDE
    let settings = RecognitionSettings(
      storage: storage, supportedLocales: supported, preferredLanguages: ["de-DE", "en-US"],
      availability: FakeAvailability(capable: [Locale(identifier: "en-US")], downloaded: [enUS]))
    #expect(settings.localeIdentifier == deDE)
    await settings.refreshCapableLocales()
    #expect(settings.localeIdentifier == deDE)
    #expect(settings.activeLocaleIdentifier == deDE)
    #expect(settings.selectedNeedsDownload)
    #expect(storage.stored == deDE)
  }

  @MainActor @Test func refreshEmptyCapableSetClearsActiveSelectionWithoutFakeFallback() async {
    let storage = InMemoryRecognitionSettingsStorage()
    storage.stored = deDE
    let settings = RecognitionSettings(
      storage: storage, supportedLocales: supported, preferredLanguages: ["de-DE", "en-US"],
      availability: FakeAvailability(capable: [], downloaded: [deDE]))
    #expect(settings.localeIdentifier == deDE)
    #expect(settings.activeLocaleIdentifier == nil)

    await settings.refreshCapableLocales()

    #expect(settings.availableLocales.isEmpty)
    #expect(settings.localeIdentifier == nil)
    #expect(settings.activeLocaleIdentifier == nil)
    #expect(settings.localeAvailabilityState == .unavailable)
    #expect(settings.selectedNeedsDownload == false)
    #expect(storage.stored == deDE)
  }

  @MainActor @Test func refreshRecoversStoredLocaleAndDownloadStateAfterEmptyCapableSet() async {
    let storage = InMemoryRecognitionSettingsStorage()
    storage.stored = frFR
    let availability = MutableFakeAvailability(capable: [], downloaded: [])
    let settings = RecognitionSettings(
      storage: storage, supportedLocales: supported, preferredLanguages: ["en-US"],
      availability: availability)

    await settings.refreshCapableLocales()
    #expect(settings.localeAvailabilityState == .unavailable)
    #expect(settings.activeLocaleIdentifier == nil)

    availability.capable = [Locale(identifier: "fr-FR")]
    availability.downloaded = []
    await settings.refreshCapableLocales()

    #expect(settings.localeAvailabilityState == .available)
    #expect(settings.localeIdentifier == frFR)
    #expect(settings.activeLocaleIdentifier == frFR)
    #expect(settings.selectedNeedsDownload)

    availability.downloaded = [frFR]
    await settings.refreshCapableLocales()
    #expect(settings.selectedNeedsDownload == false)
  }

  // selectedNeedsDownload reflects the model's installed state for the chosen language.
  @MainActor @Test func selectedNeedsDownloadWhenModelMissing() async {
    let settings = RecognitionSettings(
      storage: InMemoryRecognitionSettingsStorage(), supportedLocales: supported,
      preferredLanguages: ["fr-FR"],
      availability: FakeAvailability(capable: [Locale(identifier: "fr-FR")], downloaded: []))
    await settings.refreshCapableLocales()
    #expect(settings.localeIdentifier == frFR)
    #expect(settings.selectedNeedsDownload)
  }

  @MainActor @Test func selectedDoesNotNeedDownloadWhenModelInstalled() async {
    let settings = RecognitionSettings(
      storage: InMemoryRecognitionSettingsStorage(), supportedLocales: supported,
      preferredLanguages: ["fr-FR"],
      availability: FakeAvailability(capable: [Locale(identifier: "fr-FR")], downloaded: [frFR]))
    await settings.refreshSelectedDownloadState()
    #expect(settings.selectedNeedsDownload == false)
  }

  @MainActor @Test func localeSaveFailureSurfacesStaleSettingsIssue() {
    let storage = InMemoryRecognitionSettingsStorage()
    storage.failSaves = true
    let settings = RecognitionSettings(
      storage: storage, supportedLocales: supported, preferredLanguages: ["en-US"])

    settings.localeIdentifier = frFR

    #expect(settings.localeIdentifier == frFR)
    #expect(storage.stored == nil)
    #expect(settings.storageIssue == .recognitionLocaleSaveFailed)
    #expect(settings.hasStaleSettings)
  }

  @MainActor @Test func unsupportedStoredLocaleSurfacesCorruptionIssue() {
    let storage = InMemoryRecognitionSettingsStorage()
    storage.stored = "zz-ZZ"
    let settings = RecognitionSettings(
      storage: storage, supportedLocales: supported, preferredLanguages: ["fr-FR"])

    #expect(settings.localeIdentifier == frFR)
    #expect(settings.storageIssue == .recognitionLocaleCorrupted)
  }
}

private final class InMemoryRecognitionSettingsStorage: RecognitionSettingsStorage,
  @unchecked Sendable
{
  var stored: String?
  var engineChoice: TranscriptionEngineChoice?
  var failSaves = false
  func loadLocaleIdentifier() -> String? { stored }
  func saveLocaleIdentifier(_ identifier: String) throws {
    if failSaves { throw RecognitionSettingsTests.TestError.saveFailed }
    stored = identifier
  }
  func loadEngineChoice() -> TranscriptionEngineChoice { engineChoice ?? .apple }
  func saveEngineChoice(_ choice: TranscriptionEngineChoice) throws {
    if failSaves { throw RecognitionSettingsTests.TestError.saveFailed }
    engineChoice = choice
  }
}

private struct FakeAvailability: OnDeviceLocaleAvailability {
  let capable: Set<Locale>
  let downloaded: Set<String>
  func capableLocales() async -> Set<Locale> { capable }
  func isDownloaded(_ locale: Locale) async -> Bool { downloaded.contains(locale.identifier) }
}

private final class MutableFakeAvailability: OnDeviceLocaleAvailability, @unchecked Sendable {
  var capable: Set<Locale>
  var downloaded: Set<String>

  init(capable: Set<Locale>, downloaded: Set<String>) {
    self.capable = capable
    self.downloaded = downloaded
  }

  func capableLocales() async -> Set<Locale> { capable }
  func isDownloaded(_ locale: Locale) async -> Bool { downloaded.contains(locale.identifier) }
}
