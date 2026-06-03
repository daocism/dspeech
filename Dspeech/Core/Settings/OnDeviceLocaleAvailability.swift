import Foundation
@preconcurrency import Speech

// why: the recognition picker must list ONLY languages that can actually run on-device (a
// dictation model exists for them). Server-only locales "just hang there and won't work".
// On iOS 26 the authoritative on-device-capable list is SpeechTranscriber.supportedLocales
// (it INCLUDES not-yet-downloaded locales — exactly what a "pick then download" flow needs).
// Whether a given locale's model is downloaded/usable right now by the live engine is a
// separate signal: SFSpeechRecognizer.supportsOnDeviceRecognition. These are the two facts
// the UI needs (which to show; whether the selected one needs downloading).
protocol OnDeviceLocaleAvailability: Sendable {
  func capableLocales() async -> Set<Locale>
  func isDownloaded(_ locale: Locale) async -> Bool
}

enum OnDeviceLocaleResolver {
  static func capableLocales(
    recognizerSupported: Set<Locale>,
    onDeviceSupported: Set<Locale>
  ) -> Set<Locale> {
    guard !onDeviceSupported.isEmpty else { return [] }
    let onDeviceKeys = Set(onDeviceSupported.map { $0.identifier(.bcp47) })
    let capable = recognizerSupported.filter { onDeviceKeys.contains($0.identifier(.bcp47)) }
    if !capable.isEmpty { return capable }
    // why: intersection empty can be a BCP-47/script decoration mismatch. The
    // SpeechTranscriber list is still the authoritative on-device-capable set.
    return onDeviceSupported
  }
}

struct SystemOnDeviceLocaleAvailability: OnDeviceLocaleAvailability {
  func capableLocales() async -> Set<Locale> {
    let recognizerSupported = SFSpeechRecognizer.supportedLocales()
    guard #available(iOS 26.0, *) else { return recognizerSupported }
    // On-device-capable list (incl. not-downloaded), intersected with what the live engine
    // (SFSpeechRecognizer) can actually use. Compare by BCP-47 — SpeechTranscriber locales
    // may carry different region/script decoration than the recognizer's.
    let onDevice = await SpeechTranscriber.supportedLocales
    return OnDeviceLocaleResolver.capableLocales(
      recognizerSupported: recognizerSupported,
      onDeviceSupported: Set(onDevice))
  }

  func isDownloaded(_ locale: Locale) async -> Bool {
    guard let recognizer = SFSpeechRecognizer(locale: locale) else { return false }
    // why: poll supportsOnDeviceRecognition (the model-installed signal for the live engine) —
    // it reads false right after init until availability settles (Apple-forum-confirmed quirk).
    // Don't also require isAvailable: that conflates "model downloaded" with "authorized /
    // online" and would falsely flag a downloaded language as needing download before speech
    // authorization resolves.
    for _ in 0..<6 {
      if recognizer.supportsOnDeviceRecognition { return true }
      try? await Task.sleep(nanoseconds: 200_000_000)
    }
    return false
  }
}
