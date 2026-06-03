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

protocol RecognitionSettingsStorage: Sendable {
  func loadLocaleIdentifier() -> String?
  func saveLocaleIdentifier(_ identifier: String)
}

struct UserDefaultsRecognitionSettingsStorage: RecognitionSettingsStorage, @unchecked Sendable {
  static let localeKey = "dspeech.recognition.locale.v1"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func loadLocaleIdentifier() -> String? {
    defaults.string(forKey: Self.localeKey)
  }

  func saveLocaleIdentifier(_ identifier: String) {
    defaults.set(identifier, forKey: Self.localeKey)
  }
}

// Pure, dependency-injected locale logic so it is testable without the device's
// installed SFSpeech locales: production passes SFSpeechRecognizer.supportedLocales().
enum RecognitionLocaleCatalog {
  static let fallbackIdentifier = "en-US"

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
  ) -> String {
    let identifiers = Set(supported.map(\.identifier))
    if let stored, identifiers.contains(stored) { return stored }
    return defaultIdentifier(supported: supported, preferredLanguages: preferredLanguages)
  }

  static func defaultIdentifier(
    supported: Set<Locale>,
    preferredLanguages: [String]
  ) -> String {
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
    return identifiers.first ?? fallbackIdentifier
  }
}

@MainActor
@Observable
final class RecognitionSettings {
  private let storage: RecognitionSettingsStorage
  let availableLocales: [RecognitionLocale]

  var localeIdentifier: String {
    didSet {
      guard localeIdentifier != oldValue else { return }
      storage.saveLocaleIdentifier(localeIdentifier)
    }
  }

  init(
    storage: RecognitionSettingsStorage = UserDefaultsRecognitionSettingsStorage(),
    supportedLocales: Set<Locale> = SFSpeechRecognizer.supportedLocales(),
    preferredLanguages: [String] = Locale.preferredLanguages,
    displayLocale: Locale = .current
  ) {
    self.storage = storage
    self.availableLocales = RecognitionLocaleCatalog.sortedLocales(
      supported: supportedLocales,
      displayLocale: displayLocale
    )
    self.localeIdentifier = RecognitionLocaleCatalog.resolve(
      stored: storage.loadLocaleIdentifier(),
      supported: supportedLocales,
      preferredLanguages: preferredLanguages
    )
  }
}
