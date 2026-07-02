import SwiftUI

// why: these sections form the on-device data-governance domain — the privacy/processing disclosure,
// download-network policy, transcript retention, and the diagnostics export that is the app's ONLY
// user-initiated egress. Grouped together because each concerns what data lives on and leaves the
// device, keeping SettingsView.body a flat list of section calls.
extension SettingsView {
  var privacyProcessingSection: some View {
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

  var cellularDownloadsSection: some View {
    Section {
      Toggle(
        String(localized: "Allow downloads over cellular"),
        isOn: $downloadSettings.allowCellular
      )
      .accessibilityIdentifier("cellular-downloads-toggle")
    } footer: {
      Text(
        String(
          localized:
            "Model downloads wait for Wi-Fi unless enabled. Packs can be hundreds of megabytes."
        )
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  var storageSection: some View {
    Section {
      LabeledContent(String(localized: "Transcripts on device")) {
        if let transcriptStorageBytes {
          Text(byteString(transcriptStorageBytes))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("storage-usage-value")
        } else {
          Text(String(localized: "Calculating…"))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("storage-usage-calculating")
        }
      }
      Toggle(isOn: $retention.autoCleanupEnabled) {
        VStack(alignment: .leading, spacing: 2) {
          Text(String(localized: "Auto-delete old flights"))
            .font(.body.weight(.medium))
          Text(
            retention.autoCleanupEnabled
              ? String(
                localized:
                  "On the next launch, saved flights older than the window below are deleted from this device. The active flight is never deleted."
              )
              : String(
                localized:
                  "Off. Saved flights are kept until you delete them. Turn on to remove flights older than a chosen age at launch."
              )
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .accessibilityIdentifier("storage-autocleanup-toggle")
      if retention.autoCleanupEnabled {
        Picker(String(localized: "Delete flights older than"), selection: $retention.window) {
          ForEach(TranscriptRetentionWindow.allCases) { window in
            Text(retentionWindowLabel(window)).tag(window)
          }
        }
        .accessibilityIdentifier("storage-retention-picker")
      }
    } header: {
      Text(String(localized: "Storage"))
    } footer: {
      Text(
        String(
          localized:
            "Deletion runs only at app launch and removes whole saved flights. Transcripts never leave your device."
        )
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func retentionWindowLabel(_ window: TranscriptRetentionWindow) -> String {
    String(localized: "\(window.days) days")
  }

  // MARK: - H5 diagnostics export (local-only; export is the ONLY egress and is user-initiated)

  var diagnosticsSection: some View {
    Section {
      if diagnosticFileURLs.isEmpty {
        Text(String(localized: "No diagnostics collected yet."))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("diagnostics-empty")
      } else {
        ShareLink(items: diagnosticFileURLs) {
          Label(String(localized: "Export diagnostics"), systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("diagnostics-export")
      }
    } header: {
      Text(String(localized: "Diagnostics"))
    } footer: {
      Text(
        String(
          localized:
            "Crash and performance reports are collected on device by iOS and never leave your iPhone unless you export and share them yourself."
        )
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}
