import SwiftUI
import UIKit

extension SettingsView {
  var recognitionLocaleSection: some View {
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
            .foregroundStyle(DspeechTheme.warning)
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
          .foregroundStyle(DspeechTheme.warning)
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
  }

  var recognitionEngineSection: some View {
    Section {
      Picker(String(localized: "Engine"), selection: $recognition.engineChoice) {
        ForEach(TranscriptionEngineChoice.allCases) { choice in
          Text(choice.displayName).tag(choice)
        }
      }
      .accessibilityIdentifier("recognition-engine-picker")
      if shouldShowWhisperKitModelRows {
        whisperKitModelContent
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
  }

  private var shouldShowWhisperKitModelRows: Bool {
    recognition.engineChoice == .whisperKit || whisperKitInstaller.state.isInstalled
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

  @ViewBuilder
  private var whisperKitAbsentContent: some View {
    if whisperKitInstaller.hasPartialStaging {
      whisperKitPausedResumeContent
    } else {
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
          .foregroundStyle(DspeechTheme.warning)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        }
        Button {
          startWhisperKitDownload()
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
  }

  private var whisperKitPausedResumeContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      whisperKitStatusRow(
        title: String(localized: "Download paused"),
        detail: pausedKeptDetail(fraction: whisperKitInstaller.stagedFractionKept)
      )
      Button {
        startWhisperKitDownload()
      } label: {
        Label(String(localized: "Resume download"), systemImage: "arrow.down.circle.fill")
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("whisperkit-model-resume")
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
      Button {
        pauseWhisperKitDownload()
      } label: {
        Label(String(localized: "Pause"), systemImage: "pause.circle")
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("whisperkit-model-pause")
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
      .tint(DspeechTheme.danger)
      .accessibilityIdentifier("whisperkit-model-delete")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func whisperKitFailedContent(_ failure: WhisperKitModelInstallFailure) -> some View {
    // why: a paused (cancelled) download is not an error — surface it as a resumable pause with the
    // kept-bytes copy, not a red "install failed" retry.
    if failure.kind == .cancelled {
      whisperKitPausedResumeContent
    } else {
      VStack(alignment: .leading, spacing: 8) {
        whisperKitStatusRow(
          title: String(localized: "Model install failed"),
          detail: failure.userSafeReason
        )
        if failure.isRetryable {
          Button(String(localized: "Retry WhisperKit download")) {
            startWhisperKitDownload()
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("whisperkit-model-retry")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
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

  // MARK: - C3 pause / resume

  private func startWhisperKitDownload() {
    whisperKitDownloadTask?.cancel()
    whisperKitDownloadTask = Task { await whisperKitInstaller.install() }
  }

  private func pauseWhisperKitDownload() {
    whisperKitDownloadTask?.cancel()
    whisperKitDownloadTask = nil
  }

  private func pausedKeptDetail(fraction: Double) -> String {
    guard fraction > 0 else { return String(localized: "Paused") }
    let percent = Int((fraction * 100).rounded())
    return String(localized: "Paused — \(percent)% kept")
  }
}
