import SwiftUI
import UIKit

struct SettingsView: View {
  @Bindable var privacy: PrivacySettings
  @Bindable var recognition: RecognitionSettings
  @Bindable var translation: TranslationSettings
  @Bindable var retention: TranscriptRetentionSettings
  var audioSource: AudioSourceController
  var translationFailure: TranslationFailure?
  var captureActive: Bool
  var voiceFilter: VoiceFilterPipeline?
  var onVoiceFilterDisabled: () -> Void
  @Environment(\.dismiss) private var dismiss

  init(
    privacy: PrivacySettings, recognition: RecognitionSettings,
    translation: TranslationSettings,
    audioSource: AudioSourceController,
    translationFailure: TranslationFailure? = nil,
    captureActive: Bool = false,
    voiceFilter: VoiceFilterPipeline? = nil,
    retention: TranscriptRetentionSettings = TranscriptRetentionSettings(),
    onVoiceFilterDisabled: @escaping () -> Void = {}
  ) {
    self.privacy = privacy
    self.recognition = recognition
    self.translation = translation
    self.retention = retention
    self.audioSource = audioSource
    self.translationFailure = translationFailure
    self.captureActive = captureActive
    self.voiceFilter = voiceFilter
    self.onVoiceFilterDisabled = onVoiceFilterDisabled
  }

  // why: "" = follow the device language (default). A non-empty code writes the
  // standard AppleLanguages override, which iOS applies on the next launch -- the clean
  // in-app language switch, no bundle swizzling.
  @State var appLanguage: String = Self.currentAppLanguagePickerTag()
  @State var whisperKitInstaller = WhisperKitModelInstaller()
  // why: M1 — Wi-Fi-only download preference, owned here like the installer (SettingsView is the only
  // download-control surface). Both pinned downloaders read the same persisted key at install time.
  @State var downloadSettings = DownloadSettings()
  // why: H5 — a read-only collector over the same on-device Diagnostics directory the app-lifecycle
  // subscriber writes to (mirrors whisperKitInstaller being owned here). Used only to list files for
  // the export ShareLink; the file list is snapshotted on appear so `body` does no filesystem I/O.
  @State private var diagnostics = DiagnosticsCollector()
  @State var diagnosticFileURLs: [URL] = []
  // why: C3 — the SwiftUI download task is held so Pause can cancel it. Cancellation propagates
  // into the shared installer engine (Task.checkCancellation between files), which preserves the C1
  // staging cache, so Resume continues from the kept bytes instead of restarting at zero. This holds
  // no download logic — it only owns the task handle.
  @State var whisperKitDownloadTask: Task<Void, Never>?
  // why: C8 — transcript-store footprint computed OFF the main actor in a detached task and cached
  // here; a nil value renders as "Calculating…". Recomputed on appear and after a cleanup toggle.
  @State var transcriptStorageBytes: Int64?

  static let appLanguages: [(code: String, name: String)] = [
    ("", String(localized: "System")),
    ("en", "English"), ("ru", "Русский"), ("uk", "Українська"),
    ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"),
    ("it", "Italiano"), ("pt", "Português"), ("zh-Hans", "简体中文"), ("ja", "日本語"),
  ]

  var body: some View {
    NavigationStack {
      Form {
        if VoiceFilterFeatureFlag.speakerDiarizationEnabled {
          privacyProcessingSection
        }

        if let voiceFilter {
          VoiceFilterSettingsSection(
            pipeline: voiceFilter,
            onDisabled: onVoiceFilterDisabled)
        }

        audioSourceSection
        recognitionLocaleSection
        recognitionEngineSection
        cellularDownloadsSection
        translationSection
        appLanguageSection
        storageSection
        diagnosticsSection
        Section(String(localized: "About")) {
          LabeledContent(String(localized: "Version"), value: Bundle.main.shortVersion)
        }
      }
      .onAppear {
        audioSource.refresh()
        diagnosticFileURLs = diagnostics.fileURLs()
      }
      .task { await recognition.refreshCapableLocales() }
      .task(id: retention.autoCleanupEnabled) { await refreshTranscriptStorageUsage() }
      .onChange(of: recognition.localeIdentifier) {
        Task { await recognition.refreshSelectedDownloadState() }
      }
      .onDisappear { audioSource.stopMetering() }
      .navigationTitle(String(localized: "Settings"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(String(localized: "Done")) {
            dismiss()
          }
          .accessibilityIdentifier("settings-done-button")
        }
      }
    }
    .accessibilityIdentifier("settings-sheet")
    .preferredColorScheme(.dark)
    // why: success haptic keyed to the install STATE transition (absent/downloading -> installed),
    // never a tap — a failed or cancelled download never reaches .installed, so it can't emit
    // success. The closure form fires only on the false->true edge, so deleting the model
    // (installed -> absent) stays silent (D13, ADR 0013 rule 7).
    .sensoryFeedback(trigger: whisperKitInstaller.state.isInstalled) { wasInstalled, isInstalled in
      isInstalled && !wasInstalled ? .success : nil
    }
  }

  static func pickerTag(forStored stored: String?) -> String {
    guard let stored, !stored.isEmpty else { return "" }
    let storedLanguage = Locale(identifier: stored).language
    guard let storedCode = storedLanguage.languageCode?.identifier else { return "" }
    let storedScript = storedLanguage.script?.identifier
    for language in appLanguages where !language.code.isEmpty {
      let optionLanguage = Locale(identifier: language.code).language
      guard optionLanguage.languageCode?.identifier == storedCode else { continue }
      let optionScript = optionLanguage.script?.identifier
      if storedScript == optionScript || optionScript == nil || storedScript == nil {
        return language.code
      }
    }
    return ""
  }

  private static func currentAppLanguagePickerTag(
    bundleIdentifier: String? = Bundle.main.bundleIdentifier,
    defaults: UserDefaults = .standard
  ) -> String {
    guard let bundleIdentifier,
      let appleLanguages = defaults.persistentDomain(forName: bundleIdentifier)?["AppleLanguages"]
        as? [String]
    else { return "" }
    return pickerTag(forStored: appleLanguages.first)
  }

  func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  // MARK: - C8 storage footprint + retention cleanup

  private func refreshTranscriptStorageUsage() async {
    let bytes = await Task.detached(priority: .utility) {
      FileTranscriptStore.totalDiskUsageBytes()
    }.value
    transcriptStorageBytes = bytes
  }
}

extension Bundle {
  fileprivate var shortVersion: String {
    (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "-"
  }
}
