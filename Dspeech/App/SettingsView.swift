import SwiftUI
import UIKit

struct SettingsView: View {
  @Bindable var privacy: PrivacySettings
  @Bindable var recognition: RecognitionSettings
  @Bindable var translation: TranslationSettings
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
    onVoiceFilterDisabled: @escaping () -> Void = {}
  ) {
    self.privacy = privacy
    self.recognition = recognition
    self.translation = translation
    self.audioSource = audioSource
    self.translationFailure = translationFailure
    self.captureActive = captureActive
    self.voiceFilter = voiceFilter
    self.onVoiceFilterDisabled = onVoiceFilterDisabled
  }

  // why: "" = follow the device language (default). A non-empty code writes the
  // standard AppleLanguages override, which iOS applies on the next launch -- the clean
  // in-app language switch, no bundle swizzling.
  @State private var appLanguage: String = Self.currentAppLanguagePickerTag()
  @State private var whisperKitInstaller = WhisperKitModelInstaller()
  @State private var parakeetInstaller = ParakeetModelInstaller()

  private static let appLanguages: [(code: String, name: String)] = [
    ("", String(localized: "System")),
    ("en", "English"), ("ru", "Русский"), ("uk", "Українська"),
    ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"),
    ("it", "Italiano"), ("pt", "Português"), ("zh-Hans", "简体中文"), ("ja", "日本語"),
  ]

  private var audioSourceBinding: Binding<String> {
    Binding(get: { audioSource.selectedUID }, set: { audioSource.select(uid: $0) })
  }

  var body: some View {
    NavigationStack {
      Form {
        if VoiceFilterFeatureFlag.speakerDiarizationEnabled {
          Section {
            Toggle(isOn: $privacy.voiceFilterActive) {
              VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Pilot speaker classification"))
                  .font(.body.weight(.medium))
                Text(
                  privacy.voiceFilterActive
                    ? String(
                      localized:
                        "Confident pilot speech can be stopped before recognition. Callsign relevance filtering stays active separately."
                    )
                    : String(
                      localized:
                        "Speaker classification is off; all audio buffers pass to recognition. Callsign relevance filtering can still hide irrelevant ATC."
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
              }
            }
            .accessibilityIdentifier("voicefilter-active-toggle")
            .onChange(of: privacy.voiceFilterActive) { _, active in
              if !active { onVoiceFilterDisabled() }
            }
          } header: {
            Text(String(localized: "Privacy"))
          } footer: {
            Text(
              String(
                localized: "Dspeech processes audio locally only. Audio never leaves your device."))
          }
        }

        if let voiceFilter {
          VoiceFilterSettingsSection(
            pipeline: voiceFilter,
            onDisabled: onVoiceFilterDisabled)
        }

        Section {
          if let routeFailure = audioSource.routePreparationFailure {
            Text(routeFailure.userFacingMessage)
              .font(.footnote)
              .foregroundStyle(.red)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("audio-route-preparation-error")
          }
          if audioSource.hasSelectableInputs {
            Picker(String(localized: "Input"), selection: audioSourceBinding) {
              ForEach(audioSource.availableInputs, id: \.uid) { input in
                Text(input.portName).tag(input.uid)
              }
            }
            .accessibilityIdentifier("audio-source-picker")
          } else if audioSource.routePreparationFailure == nil {
            Text(
              String(
                localized:
                  "No input source detected. Connect a wired input (USB-C / TRRS) or use the built-in microphone."
              )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
          }
          if let selectionError = audioSource.selectionError {
            Text(selectionError)
              .font(.footnote)
              .foregroundStyle(.orange)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("audio-source-error")
          }
          Button {
            if audioSource.isMetering {
              audioSource.stopMetering()
            } else {
              audioSource.startMetering()
            }
          } label: {
            Label(
              audioSource.isMetering
                ? String(localized: "Stop test") : String(localized: "Test input level"),
              systemImage: audioSource.isMetering ? "stop.circle" : "waveform")
          }
          .disabled(captureActive)
          .accessibilityIdentifier("audio-meter-toggle")
          if audioSource.isMetering {
            HStack(spacing: 12) {
              Text(String(localized: "Level")).font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
              InputLevelBar(level: audioSource.inputLevel).frame(height: 8)
            }
            .accessibilityIdentifier("audio-input-level")
          }
          if let inputLevelError = audioSource.inputLevelError {
            Text(inputLevelError)
              .font(.footnote)
              .foregroundStyle(.orange)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("audio-meter-error")
          }
        } header: {
          Text(String(localized: "Audio source"))
        } footer: {
          Text(
            String(
              localized:
                "Your choice is saved for this device. The built-in microphone is for testing; for the cockpit, connect a wired input."
            )
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        }
        Section(String(localized: "Recognition")) {
          switch recognition.localeAvailabilityState {
          case .loading:
            HStack {
              ProgressView()
              Text(String(localized: "Checking on-device recognition languages…"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("recognition-locale-loading")
          case .available:
            Picker(
              String(localized: "Recognition language"), selection: $recognition.localeIdentifier
            ) {
              ForEach(recognition.availableLocales) { locale in
                Text(locale.displayName).tag(Optional(locale.identifier))
              }
            }
            .accessibilityIdentifier("recognition-locale-picker")
          case .unavailable:
            VStack(alignment: .leading, spacing: 6) {
              Text(String(localized: "No on-device recognition languages available."))
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
              Text(
                String(
                  localized:
                    "Check dictation languages in device Settings. Dspeech won't fall back to cloud recognition in place of local mode."
                )
              )
              .font(.footnote)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("recognition-locale-unavailable")
          }
          if recognition.selectedNeedsDownload {
            VStack(alignment: .leading, spacing: 6) {
              Text(
                String(
                  localized:
                    "The language “\(recognition.selectedDisplayName)” has not been downloaded yet for on-device recognition."
                )
              )
              .font(.footnote)
              .foregroundStyle(.orange)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("recognition-download-hint")
              Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                  UIApplication.shared.open(url)
                }
              } label: {
                Label(String(localized: "Open Device Settings"), systemImage: "gearshape")
              }
              .accessibilityIdentifier("recognition-download-language")
              Text(
                String(
                  localized:
                    "Then: General -> Keyboard -> Dictation Languages -- turn on Dictation and add this language. The model downloads, and recognition works offline."
                )
              )
              .font(.footnote)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
            }
          }
          LabeledContent(String(localized: "Mode"), value: privacy.mode.displayName)
        }
        Section {
          Picker(String(localized: "Engine"), selection: $recognition.engineChoice) {
            ForEach(TranscriptionEngineChoice.allCases) { choice in
              // why: Parakeet EOU is English-only — never offer it for a non-en recognition
              // locale (the model would hallucinate on other languages). Hiding the option (vs
              // disabling) avoids implying a configuration that can't apply. (ADR-0012.)
              if choice != .parakeet || isParakeetSelectable {
                Text(choice.displayName).tag(choice)
              }
            }
          }
          .accessibilityIdentifier("recognition-engine-picker")
          if shouldShowWhisperKitModelRows {
            whisperKitModelContent
          }
          if shouldShowParakeetModelRows {
            parakeetModelContent
          }
        } header: {
          Text(String(localized: "Recognition engine"))
        } footer: {
          Text(
            String(
              localized:
                "Apple Speech stays active until the WhisperKit model is installed locally. Model downloads happen only when you tap Download."
            )
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        }
        Section {
          Toggle(String(localized: "On-device translation"), isOn: $translation.enabled)
            .accessibilityIdentifier("translation-enabled-toggle")
          Picker(String(localized: "Target language"), selection: $translation.targetCode) {
            ForEach(translation.availableTargets) { option in
              Text(targetPickerLabel(for: option)).tag(option.code)
            }
          }
          .accessibilityIdentifier("translation-target-picker")
          if translation.enabled, let translationFailure {
            Label(
              TranslationFailureText.userFacing(translationFailure),
              systemImage: "exclamationmark.triangle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("translation-failure")
          }
        } header: {
          Text(String(localized: "Translation"))
        } footer: {
          Text(
            String(
              localized:
                "Translation runs on-device via Apple's system language packs. The first time you enable it, iOS offers to download a language pack. Audio and text never leave your device."
            )
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        }
        Section {
          Picker(String(localized: "App language"), selection: $appLanguage) {
            ForEach(Self.appLanguages, id: \.code) { lang in
              Text(lang.name).tag(lang.code)
            }
          }
          .accessibilityIdentifier("app-language-picker")
          .onChange(of: appLanguage) { _, code in
            if code.isEmpty {
              UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
              UserDefaults.standard.set([code], forKey: "AppleLanguages")
            }
          }
        } header: {
          Text(String(localized: "App language"))
        } footer: {
          Text(String(localized: "Restart the app to change the language."))
        }
        Section(String(localized: "About")) {
          LabeledContent(String(localized: "Version"), value: Bundle.main.shortVersion)
        }
      }
      .onAppear { audioSource.refresh() }
      .task { await recognition.refreshCapableLocales() }
      .onChange(of: recognition.localeIdentifier) {
        Task { await recognition.refreshSelectedDownloadState() }
        // why: if the user switches to a non-English recognition locale while Parakeet is the
        // selected engine, the (English-only) Parakeet tag disappears from the picker. Reset to
        // Apple so the picker never shows a selection that no longer exists. This is deselection,
        // never auto-selection. (ADR-0012.)
        if recognition.engineChoice == .parakeet, !isParakeetSelectable {
          recognition.engineChoice = .apple
        }
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

  private func targetPickerLabel(for option: TranslationLanguageOption) -> String {
    guard let sourceIdentifier = recognition.activeLocaleIdentifier,
      ContentView.sameLanguageTranslationFailure(
        sourceIdentifier: sourceIdentifier,
        targetCode: option.code) != nil
    else { return option.displayName }
    return String(localized: "\(option.displayName) (current speech language)")
  }

  private var shouldShowWhisperKitModelRows: Bool {
    recognition.engineChoice == .whisperKit || whisperKitInstaller.state.isInstalled
  }

  // why: Parakeet EOU is English-only — selectable only when the recognition locale is en-*.
  private var isParakeetSelectable: Bool {
    recognition.localeIdentifier?.hasPrefix("en") == true
  }

  private var shouldShowParakeetModelRows: Bool {
    recognition.engineChoice == .parakeet || parakeetInstaller.state.isInstalled
  }

  @ViewBuilder
  private var parakeetModelContent: some View {
    switch parakeetInstaller.state {
    case .absent:
      parakeetAbsentContent
    case .downloading(let progress):
      parakeetDownloadingContent(progress)
    case .installed(let model):
      parakeetInstalledContent(model)
    case .failed(let failure):
      parakeetFailedContent(failure)
    }
  }

  private var parakeetAbsentContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      parakeetStatusRow(
        title: String(localized: "Parakeet model not installed"),
        detail: String(localized: "Required download") + ": "
          + byteString(ParakeetModelInstaller.expectedModelSizeBytes)
      )
      if recognition.engineChoice == .parakeet {
        Text(
          String(
            localized:
              "Download the Parakeet model before using it. Until then, Dspeech falls back to Apple Speech."
          )
        )
        .font(.footnote)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
      }
      Button {
        Task { await parakeetInstaller.install() }
      } label: {
        Label(
          String(
            localized:
              "Install Parakeet (English, \(byteString(ParakeetModelInstaller.expectedModelSizeBytes)))"
          ),
          systemImage: "arrow.down.circle.fill"
        )
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("parakeet-model-download")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func parakeetDownloadingContent(_ progress: ParakeetModelDownloadProgress)
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      parakeetStatusRow(
        title: String(localized: "Downloading Parakeet model"),
        detail: "\(progress.percentComplete)% · \(byteString(progress.totalBytes))"
      )
      ProgressView(value: progress.fractionComplete)
      Label(
        String(localized: "Downloading") + " \(progress.percentComplete)%",
        systemImage: "arrow.down.circle.fill"
      )
      .font(.footnote.weight(.medium))
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("parakeet-model-downloading")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func parakeetInstalledContent(_ model: ParakeetInstalledModel) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      parakeetStatusRow(
        title: String(localized: "Parakeet model installed"),
        detail: "\(model.name) · \(byteString(model.sizeBytes))"
      )
      Button(String(localized: "Delete Parakeet model")) {
        Task { await parakeetInstaller.deleteInstalledModel() }
      }
      .buttonStyle(.bordered)
      .tint(.red)
      .accessibilityIdentifier("parakeet-model-delete")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func parakeetFailedContent(_ failure: ParakeetModelInstallFailure) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      parakeetStatusRow(
        title: String(localized: "Parakeet model install failed"),
        detail: failure.userSafeReason
      )
      if failure.isRetryable {
        Button(String(localized: "Retry Parakeet download")) {
          Task { await parakeetInstaller.install() }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("parakeet-model-retry")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func parakeetStatusRow(title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.body.weight(.medium))
      Text(detail)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("parakeet-model-status")
  }

  @ViewBuilder
  private var whisperKitModelContent: some View {
    switch whisperKitInstaller.state {
    case .absent:
      whisperKitAbsentContent
    case .downloading(let progress):
      whisperKitDownloadingContent(progress)
    case .installed(let model):
      whisperKitInstalledContent(model)
    case .failed(let failure):
      whisperKitFailedContent(failure)
    }
  }

  private var whisperKitAbsentContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      whisperKitStatusRow(
        title: String(localized: "Model not installed"),
        detail: String(localized: "Required download") + ": "
          + byteString(WhisperKitModelInstaller.expectedModelSizeBytes)
      )
      if recognition.engineChoice == .whisperKit {
        Text(
          String(
            localized:
              "Download the model before using WhisperKit. Until then, Dspeech falls back to Apple Speech."
          )
        )
        .font(.footnote)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
      }
      Button {
        Task { await whisperKitInstaller.install() }
      } label: {
        Label(
          String(localized: "Download WhisperKit model") + " ("
            + byteString(WhisperKitModelInstaller.expectedModelSizeBytes) + ")",
          systemImage: "arrow.down.circle.fill"
        )
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("whisperkit-model-download")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func whisperKitDownloadingContent(_ progress: WhisperKitModelDownloadProgress)
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      whisperKitStatusRow(
        title: String(localized: "Downloading model"),
        detail: "\(progress.percentComplete)% · \(byteString(progress.totalBytes))"
      )
      ProgressView(value: progress.fractionComplete)
      Label(
        String(localized: "Downloading") + " \(progress.percentComplete)%",
        systemImage: "arrow.down.circle.fill"
      )
      .font(.footnote.weight(.medium))
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("whisperkit-model-downloading")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func whisperKitInstalledContent(_ model: WhisperKitInstalledModel) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      whisperKitStatusRow(
        title: String(localized: "Model installed"),
        detail: "\(model.name) · \(byteString(model.sizeBytes))"
      )
      Button(String(localized: "Delete WhisperKit model")) {
        Task { await whisperKitInstaller.deleteInstalledModel() }
      }
      .buttonStyle(.bordered)
      .tint(.red)
      .accessibilityIdentifier("whisperkit-model-delete")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func whisperKitFailedContent(_ failure: WhisperKitModelInstallFailure) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      whisperKitStatusRow(
        title: String(localized: "Model install failed"),
        detail: failure.userSafeReason
      )
      if failure.isRetryable {
        Button(String(localized: "Retry WhisperKit download")) {
          Task { await whisperKitInstaller.install() }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("whisperkit-model-retry")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func whisperKitStatusRow(title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.body.weight(.medium))
      Text(detail)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("whisperkit-model-status")
  }

  private func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

extension Bundle {
  fileprivate var shortVersion: String {
    (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "-"
  }
}
