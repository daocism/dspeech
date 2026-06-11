import Foundation
import Observation
import Speech

// why: the live ASR locale must be user-selectable. ATC is conducted in the local
// language (French in France, etc.), so a hardcoded en-US recognizer returns garbage
// or empty transcripts for non-English audio. The locale is validated against the
// recognizer's supported set so an unsupported stored value can never reach SFSpeech.

struct RecognitionLocale: Identifiable, Equatable, Sendable {
  let identifier: String
  let displayName: String
  var id: String { identifier }
}

enum RecognitionLocaleAvailabilityState: Equatable, Sendable {
  case loading
  case available
  case unavailable
}

enum TranscriptionEngineChoice: String, Codable, Sendable, CaseIterable, Identifiable {
  case apple
  case whisperKit

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .apple:
      return String(localized: "Apple Speech")
    case .whisperKit:
      return String(localized: "WhisperKit")
    }
  }
}

protocol RecognitionSettingsStorage: Sendable {
  func loadLocaleIdentifier() -> String?
  func saveLocaleIdentifier(_ identifier: String) throws
  func loadEngineChoice() -> TranscriptionEngineChoice
  func saveEngineChoice(_ choice: TranscriptionEngineChoice) throws
  func loadIssue() -> SettingsStorageIssue?
}

extension RecognitionSettingsStorage {
  func loadIssue() -> SettingsStorageIssue? { nil }
}

struct UserDefaultsRecognitionSettingsStorage: RecognitionSettingsStorage, @unchecked Sendable {
  static let localeKey = "dspeech.recognition.locale.v1"
  static let engineChoiceKey = "dspeech.recognition.engine.v1"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func loadLocaleIdentifier() -> String? {
    defaults.string(forKey: Self.localeKey)
  }

  func saveLocaleIdentifier(_ identifier: String) throws {
    defaults.set(identifier, forKey: Self.localeKey)
  }

  func loadEngineChoice() -> TranscriptionEngineChoice {
    guard let raw = defaults.string(forKey: Self.engineChoiceKey),
      let choice = TranscriptionEngineChoice(rawValue: raw)
    else {
      return .apple
    }
    return choice
  }

  func saveEngineChoice(_ choice: TranscriptionEngineChoice) throws {
    defaults.set(choice.rawValue, forKey: Self.engineChoiceKey)
  }

  func loadIssue() -> SettingsStorageIssue? {
    if let raw = defaults.string(forKey: Self.engineChoiceKey),
      TranscriptionEngineChoice(rawValue: raw) == nil
    {
      return .recognitionLocaleCorrupted
    }
    return nil
  }
}

// Pure, dependency-injected locale logic so it is testable without the device's
// installed SFSpeech locales: production passes SFSpeechRecognizer.supportedLocales().
enum RecognitionLocaleCatalog {
  static func sortedLocales(
    supported: Set<Locale>,
    displayLocale: Locale = .current
  ) -> [RecognitionLocale] {
    supported
      .map { locale in
        RecognitionLocale(
          identifier: locale.identifier,
          displayName: displayLocale.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
        )
      }
      .sorted {
        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      }
  }

  static func resolve(
    stored: String?,
    supported: Set<Locale>,
    preferredLanguages: [String]
  ) -> String? {
    let identifiers = Set(supported.map(\.identifier))
    if let stored, identifiers.contains(stored) { return stored }
    return defaultIdentifier(supported: supported, preferredLanguages: preferredLanguages)
  }

  static func defaultIdentifier(
    supported: Set<Locale>,
    preferredLanguages: [String]
  ) -> String? {
    // why: the default recognition language ALWAYS follows the device language when Apple
    // Speech supports it (English is only a last resort when the device language is fully
    // unsupported). Sort for deterministic region selection. Compare via canonical Locale
    // identifiers / codes, never raw strings — Locale canonicalizes "ru-RU" -> "ru_RU", so
    // a string compare against BCP-47 preferredLanguages would silently miss.
    let identifiers = supported.map(\.identifier).sorted()
    for preferred in preferredLanguages {
      let preferredLocale = Locale(identifier: preferred)
      // exact device locale (e.g. ru_RU) wins
      if identifiers.contains(preferredLocale.identifier) { return preferredLocale.identifier }
      guard let preferredLanguage = preferredLocale.language.languageCode?.identifier else {
        continue
      }
      let sameLanguage = identifiers.filter {
        Locale(identifier: $0).language.languageCode?.identifier == preferredLanguage
      }
      guard !sameLanguage.isEmpty else { continue }
      // same language code: prefer the device's region, else the first (sorted) variant
      if let region = preferredLocale.region?.identifier,
        let regional = sameLanguage.first(where: {
          Locale(identifier: $0).region?.identifier == region
        })
      {
        return regional
      }
      return sameLanguage[0]
    }
    // why: English fallback only when the device language has no supported variant at all.
    if let english = identifiers.first(where: {
      Locale(identifier: $0).language.languageCode?.identifier == "en"
    }) {
      return english
    }
    return identifiers.first
  }
}

@MainActor
@Observable
final class RecognitionSettings {
  private let storage: RecognitionSettingsStorage
  private let availability: OnDeviceLocaleAvailability
  private let preferredLanguages: [String]
  private let displayLocale: Locale
  // why: starts as the recognizer's full supported set (sync, so the picker is never empty at
  // launch) and is narrowed to the on-device-CAPABLE set by refreshCapableLocales().
  private(set) var availableLocales: [RecognitionLocale]
  private(set) var localeAvailabilityState: RecognitionLocaleAvailabilityState
  // why: drives the "Download <language>" affordance — true when the selected locale is
  // capable on-device but its model isn't downloaded yet. Updated async (model state is I/O).
  private(set) var selectedNeedsDownload = false
  private(set) var storageIssue: SettingsStorageIssue?
  var hasStaleSettings: Bool { storageIssue != nil }
  // why: the download-state check is async I/O; a fast picker change can spawn overlapping
  // checks that finish out of order and write a stale result. Each check captures the
  // current generation; only the latest one is allowed to commit (kills the race).
  @ObservationIgnored private var downloadStateGeneration = 0

  var localeIdentifier: String? {
    didSet {
      guard localeIdentifier != oldValue else { return }
      if let localeIdentifier {
        do {
          try storage.saveLocaleIdentifier(localeIdentifier)
          storageIssue = nil
        } catch {
          storageIssue = .recognitionLocaleSaveFailed
        }
      } else {
        selectedNeedsDownload = false
      }
    }
  }

  var engineChoice: TranscriptionEngineChoice {
    didSet {
      guard engineChoice != oldValue else { return }
      do {
        try storage.saveEngineChoice(engineChoice)
        storageIssue = nil
      } catch {
        storageIssue = .recognitionLocaleSaveFailed
      }
    }
  }

  var selectedDisplayName: String {
    guard let localeIdentifier else {
      return String(localized: "No recognition language available")
    }
    return availableLocales.first { $0.identifier == localeIdentifier }?.displayName
      ?? displayLocale.localizedString(forIdentifier: localeIdentifier) ?? localeIdentifier
  }

  init(
    storage: RecognitionSettingsStorage = UserDefaultsRecognitionSettingsStorage(),
    supportedLocales: Set<Locale> = SFSpeechRecognizer.supportedLocales(),
    preferredLanguages: [String] = Locale.preferredLanguages,
    displayLocale: Locale = .current,
    availability: OnDeviceLocaleAvailability = SystemOnDeviceLocaleAvailability()
  ) {
    self.storage = storage
    self.availability = availability
    self.preferredLanguages = preferredLanguages
    self.displayLocale = displayLocale
    self.availableLocales = RecognitionLocaleCatalog.sortedLocales(
      supported: supportedLocales,
      displayLocale: displayLocale
    )
    self.localeAvailabilityState = .loading
    self.engineChoice = storage.loadEngineChoice()
    let storedIdentifier = storage.loadLocaleIdentifier()
    self.localeIdentifier = RecognitionLocaleCatalog.resolve(
      stored: storedIdentifier,
      supported: supportedLocales,
      preferredLanguages: preferredLanguages
    )
    if let storedIdentifier, storedIdentifier != self.localeIdentifier {
      self.storageIssue = .recognitionLocaleCorrupted
    } else {
      self.storageIssue = storage.loadIssue()
    }
  }

  var activeLocaleIdentifier: String? {
    localeAvailabilityState == .available ? localeIdentifier : nil
  }

  // why: narrow the picker to languages Apple can actually recognize on-device, and keep the
  // current selection valid against that narrowed set. Call from the Settings view.
  func refreshCapableLocales() async {
    localeAvailabilityState = .loading
    let capable = await availability.capableLocales()
    availableLocales = RecognitionLocaleCatalog.sortedLocales(
      supported: capable, displayLocale: displayLocale)
    guard !capable.isEmpty else {
      localeIdentifier = nil
      selectedNeedsDownload = false
      localeAvailabilityState = .unavailable
      return
    }
    if localeIdentifier == nil {
      localeIdentifier =
        storage.loadLocaleIdentifier()
        ?? RecognitionLocaleCatalog.defaultIdentifier(
          supported: capable,
          preferredLanguages: preferredLanguages)
    }
    localeAvailabilityState = .available
    await refreshSelectedDownloadState()
  }

  func refreshSelectedDownloadState() async {
    downloadStateGeneration += 1
    let generation = downloadStateGeneration
    guard let localeIdentifier else {
      selectedNeedsDownload = false
      return
    }
    let downloaded = await availability.isDownloaded(Locale(identifier: localeIdentifier))
    // why: a newer check superseded this one (fast picker change) — drop the stale result so
    // selectedNeedsDownload always reflects the CURRENT selection, not whichever async check
    // happened to finish last.
    guard generation == downloadStateGeneration else { return }
    selectedNeedsDownload = !downloaded
  }
}
