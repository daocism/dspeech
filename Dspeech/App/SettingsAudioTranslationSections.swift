import SwiftUI

extension SettingsView {
  private var audioSourceBinding: Binding<String> {
    Binding(get: { audioSource.selectedUID }, set: { audioSource.select(uid: $0) })
  }

  var audioSourceSection: some View {
    Section {
      if let routeFailure = audioSource.routePreparationFailure {
        Text(routeFailure.userFacingMessage)
          .font(.footnote)
          .foregroundStyle(DspeechTheme.danger)
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
          .foregroundStyle(DspeechTheme.warning)
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
          .foregroundStyle(DspeechTheme.warning)
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
  }

  var translationSection: some View {
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
        .foregroundStyle(DspeechTheme.warning)
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
  }

  var appLanguageSection: some View {
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
  }

  private func targetPickerLabel(for option: TranslationLanguageOption) -> String {
    guard let sourceIdentifier = recognition.activeLocaleIdentifier,
      ContentView.sameLanguageTranslationFailure(
        sourceIdentifier: sourceIdentifier,
        targetCode: option.code) != nil
    else { return option.displayName }
    return String(localized: "\(option.displayName) (current speech language)")
  }
}
