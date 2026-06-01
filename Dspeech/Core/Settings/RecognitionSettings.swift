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
    let identifiers = supported.map(\.identifier)
    for preferred in preferredLanguages {
      guard let preferredLanguage = Locale(identifier: preferred).language.languageCode?.identifier
      else { continue }
      if let match = identifiers.first(where: {
        Locale(identifier: $0).language.languageCode?.identifier == preferredLanguage
      }) {
        return match
      }
    }
    // why: match English by language code, not the literal "en-US" — Locale may
    // canonicalize identifiers (en-US -> en_US), so a string compare would miss.
    if let english = identifiers.first(where: {
      Locale(identifier: $0).language.languageCode?.identifier == "en"
    }) {
      return english
    }
    return identifiers.sorted().first ?? fallbackIdentifier
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
