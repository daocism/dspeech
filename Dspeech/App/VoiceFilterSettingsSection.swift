import SwiftUI

// why: enrollment targets a member of the variable-length crew roster — either an existing profile
// (re-record, keep its id) or a brand-new one (append). Replaces the old fixed primary/secondary slot.
enum CrewEnrollmentTarget: Equatable {
  case existing(UUID)
  case new
}

struct VoiceFilterSettingsSection: View {
  let pipeline: VoiceFilterPipeline
  let onDisabled: () -> Void

  @State private var enabled: Bool
  @State private var callsignDraft: String
  @State private var modelPackAcquisition: ModelPackAcquisitionController
  @State private var storageIssues: [VoiceFilterStorageIssue]
  @State private var dictation = CallsignDictationService()
  @State private var recorder = VoiceEnrollmentRecorder()
  // why: SwiftUI mirror of pipeline.profiles (the pipeline is not @Observable). Re-assigned after
  // every enroll/remove so the dynamic crew list re-renders.
  @State private var crewProfiles: [PilotVoiceProfile]
  @State private var recordingTarget: CrewEnrollmentTarget?
  @State private var enrollMessage: String?
  private let installer: SpeakerModelPackInstaller

  init(pipeline: VoiceFilterPipeline, onDisabled: @escaping () -> Void = {}) {
    self.pipeline = pipeline
    self.onDisabled = onDisabled
    let installer = SpeakerModelPackInstaller()
    self.installer = installer
    _enabled = State(initialValue: pipeline.enabled)
    _callsignDraft = State(initialValue: pipeline.callSign?.raw ?? "")
    _modelPackAcquisition = State(
      initialValue: ModelPackAcquisitionController(
        initialState: pipeline.modelPackState,
        installer: installer
      ) { state in
        pipeline.setModelPackState(state)
      }
    )
    _storageIssues = State(initialValue: pipeline.storageIssues)
    _crewProfiles = State(initialValue: pipeline.profiles)
  }

  private var identifierAvailable: Bool {
    if case .ready = pipeline.capability { return true }
    return false
  }

  private var modelSourceLabel: String {
    // why: the raw model repository slug is too long for localized Settings form copy and
    // triggers real text-clipping in German. The detailed repository is documented in the
    // installer/ADR; the UI needs a short, readable package label.
    String(localized: "Core ML")
  }

  var body: some View {
    Section {
      // why: the description is its own row, not the Toggle's label -- a Toggle reserves room
      // for the switch and clips a long localized subtitle (e.g. German) beside it.
      Toggle(isOn: $enabled) {
        Text(String(localized: "ATC/pilot filter"))
          .font(.body.weight(.medium))
      }
      .accessibilityIdentifier("voicefilter-enabled-toggle")
      .onChange(of: enabled) { _, newValue in
        pipeline.setEnabled(newValue)
        if !newValue { onDisabled() }
      }
      Text(
        enabled
          ? String(localized: "Hide pilot transmissions and irrelevant ATC calls.")
          : String(localized: "All ATC segments are shown.")
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)

      if !storageIssues.isEmpty {
        storageRecoveryContent
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(String(localized: "Aircraft callsign"))
          .font(.body.weight(.medium))
        HStack(spacing: 8) {
          TextField("N123AB", text: $callsignDraft)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled(true)
            .accessibilityIdentifier("voicefilter-callsign-field")
          dictationButton
        }
        Text(dictationHint)
          .font(.footnote)
          .foregroundStyle(dictation.unavailableReason == nil ? Color.secondary : Color.orange)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .onChange(of: callsignDraft) { _, newValue in
        pipeline.setCallSign(newValue.isEmpty ? nil : newValue)
      }
      .onChange(of: dictation.liveTranscript) { _, transcript in
        guard dictation.isListening else { return }
        let parsed = PhoneticCallsignParser.parse(transcript)
        if !parsed.isEmpty { callsignDraft = parsed }
      }

      // why: the FluidAudio speaker-diarization pack download + crew enrollment (ADR 0008) ship ON by
      // default now that the eval lanes are green; `-dspeech.voicefilter.diarization.disable` forces
      // them off. The phase-1 callsign filter above (ADR 0007) is always available.
      if VoiceFilterFeatureFlag.speakerDiarizationEnabled {
        modelPackContent
      }
    } header: {
      Text(String(localized: "ATC voice filter"))
    } footer: {
      Text(
        String(
          localized:
            "The filter only hides transmissions addressed to other aircraft after they are transcribed. Nothing is deleted — hidden transmissions stay in the filtered list and in history."
        )
      )
    }
    .onDisappear { stopTransientCapture() }
  }

  private var dictationButton: some View {
    Button {
      Task { await dictation.toggle() }
    } label: {
      Image(systemName: dictation.isListening ? "stop.circle.fill" : "mic.circle.fill")
        .font(.system(size: 26))
        .foregroundStyle(dictation.isListening ? Color.red : Color.cyan)
        .symbolEffect(.pulse, isActive: dictation.isListening)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("voicefilter-callsign-dictate")
    .accessibilityLabel(
      dictation.isListening
        ? String(localized: "Stop voice input") : String(localized: "Set callsign by voice"))
  }

  private var dictationHint: String {
    if let reason = dictation.unavailableReason {
      return reason
    }
    if dictation.isListening {
      return
        String(
          localized:
            "Listening -- spell out the callsign (for example: \"november one two three alpha bravo\")."
        )
    }
    return callsignDraft.isEmpty
      ? String(
        localized:
          "Without a callsign, the filter passes all non-pilot segments. Tap the microphone to set it by voice."
      )
      : String(
        localized:
          "Segments with no callsign match will be hidden while the continuation window is active.")
  }

  private var storageRecoveryContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        String(localized: "Local settings are corrupted"),
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.orange)
      Text(VoiceFilterStorageIssue.userFacingSummary(storageIssues))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
      Button(String(localized: "Reset corrupted data")) {
        pipeline.clearStorageIssues()
        storageIssues = pipeline.storageIssues
        enabled = pipeline.enabled
        callsignDraft = pipeline.callSign?.raw ?? ""
        // why: clearStorageIssues wipes profiles when they were corrupted — re-sync the mirror so
        // the crew roster doesn't keep showing ghost rows that no longer exist in the pipeline.
        crewProfiles = pipeline.profiles
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("voicefilter-storage-recovery")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("voicefilter-storage-corrupt")
  }

  @ViewBuilder
  private var modelPackContent: some View {
    switch modelPackAcquisition.state {
    case .absent:
      absentContent
    case .acquiring(let acquisition):
      acquiringContent(acquisition)
    case .installed(let pack):
      installedContent(pack)
    case .failed(let failure):
      failedContent(failure)
    case .disabled(let pack):
      disabledContent(pack)
    }
  }

  private func transition(to state: ModelPackState) {
    modelPackAcquisition.setState(state)
  }

  private func startDownload() {
    modelPackAcquisition.startDownload()
  }

  private func cancelDownload() {
    modelPackAcquisition.cancelDownload()
  }

  private func stopTransientCapture() {
    dictation.stop()
    recordingTarget = nil
    Task { @MainActor in
      await recorder.stop()
    }
  }

  private func deleteModelPack(_ pack: InstalledModelPack) async {
    do {
      let installer = installer
      try await Task.detached {
        try installer.uninstall(pack)
      }.value
      // why: wipe enrolled voice prints together with the model — don't leave personal voice data on
      // disk after the user deleted the feature that uses it (2026-06-14 audit).
      pipeline.removeAllCrewMembers()
      crewProfiles = pipeline.profiles
      transition(to: .absent)
    } catch {
      transition(to: .failed(modelPackDeleteFailure(for: error)))
    }
  }

  private func crewDisplayName(index: Int) -> String {
    String(localized: "Crew \(index + 1)")
  }

  private func crewRowSubtitle(isRecording: Bool) -> String {
    if isRecording {
      return String(
        localized: "Recording -- keep speaking for about 4 seconds, then tap Stop.")
    }
    return String(localized: "Voice sample recorded. Re-record to update it.")
  }

  private func toggleEnrollment(target: CrewEnrollmentTarget) async {
    if recordingTarget == target {
      await finishEnrollment(target: target)
      return
    }
    enrollMessage = nil
    recordingTarget = target
    await recorder.start()
    if !recorder.isRecording {
      recordingTarget = nil
      enrollMessage = recorder.unavailableReason ?? String(localized: "Couldn't start recording.")
    }
  }

  private func finishEnrollment(target: CrewEnrollmentTarget) async {
    let result = await recorder.stop()
    recordingTarget = nil
    guard let result else {
      // why: surface the recorder's ACTUAL reason (e.g. "speak for at least 4 seconds") instead of
      // a generic "recording failed" — the generic message is what made enrollment look broken.
      enrollMessage =
        recorder.unavailableReason ?? String(localized: "Recording failed -- try again.")
      return
    }
    let replacingID: UUID?
    if case .existing(let id) = target { replacingID = id } else { replacingID = nil }
    do {
      let profile = try await pipeline.enrollCrewMember(
        replacing: replacingID,
        label: crewDisplayName(index: crewProfiles.count),
        samples: result.samples,
        sampleRate: result.sampleRate
      )
      crewProfiles = pipeline.profiles
      let name =
        crewProfiles.firstIndex(where: { $0.id == profile.id }).map { crewDisplayName(index: $0) }
        ?? profile.label
      enrollMessage = String(localized: "Voice saved for \(name).")
    } catch LocalSpeakerIdentifierError.insufficientSpeech {
      enrollMessage = String(localized: "Too quiet or too short -- record a clearer sample.")
    } catch {
      enrollMessage = String(localized: "Couldn't save the voice sample. Try again.")
    }
  }

  private func removeCrewMember(id: UUID) {
    pipeline.removeCrewMember(id: id)
    crewProfiles = pipeline.profiles
    enrollMessage = nil
  }

  private var absentContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "arrow.down.circle")
        Text(String(localized: "Model not installed"))
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.secondary)
      Text(
        String(
          localized:
            "The pilot voice filter works only after the local model pack is installed. The download is one-time, explicit, and on your request; audio never leaves your device."
        )
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      Button {
        startDownload()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "arrow.down.circle.fill")
          Text(String(localized: "Download voice filter pack (≈ 15 MB)"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.vertical, 3)
      }
      .buttonStyle(.borderedProminent)
      .tint(.cyan)
      .foregroundStyle(.black)
      .controlSize(.large)
      .padding(.top, 2)
      .accessibilityIdentifier("voicefilter-modelpack-download-cta")
      Text(
        String(
          localized:
            "The FluidAudio model (\(modelSourceLabel)) is downloaded once at this request. Only the model download request leaves the device -- audio, transcripts and voice samples are not transmitted."
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("voicefilter-modelpack-absent")
  }

  private func acquiringContent(_ acquisition: ModelPackAcquisition) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(acquisitionTitle(acquisition.phase))
        .font(.subheadline.weight(.semibold))
      ProgressView(value: acquisition.fractionComplete)
        .accessibilityIdentifier("voicefilter-modelpack-progress")
      Text("\(acquisition.percentComplete)%")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("voicefilter-modelpack-percent")
      if let received = acquisition.bytesReceived, let total = acquisition.totalBytes {
        Text(String(localized: "\(byteString(received)) of \(byteString(total))"))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Button(String(localized: "Cancel")) {
        cancelDownload()
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("voicefilter-modelpack-cancel")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("voicefilter-modelpack-acquiring")
  }

  private func installedContent(_ pack: InstalledModelPack) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(String(localized: "Model installed and verified"), systemImage: "checkmark.seal.fill")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.green)
      Text(
        String(
          localized:
            "Pack “\(pack.identifier)” · \(pack.embeddingDimension)-dimensional embeddings · \(byteString(pack.sizeBytes)). Recognition runs offline."
        )
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)

      if !identifierAvailable {
        VStack(alignment: .leading, spacing: 6) {
          Label(
            String(localized: "Voice recording unavailable"),
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.orange)
          Text(
            String(
              localized:
                "The pack is installed, but the local recognizer isn't connected in this build, so voice recording is disabled."
            )
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("voicefilter-capability-banner")
      }

      crewRosterContent

      if let enrollMessage {
        Text(enrollMessage)
          .font(.footnote)
          .foregroundStyle(.cyan)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("voicefilter-enroll-message")
      }

      Button(String(localized: "Delete pack")) {
        Task { await deleteModelPack(pack) }
      }
      .buttonStyle(.bordered)
      .tint(.red)
      .accessibilityIdentifier("voicefilter-modelpack-delete")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("voicefilter-modelpack-installed")
  }

  private func failedContent(_ failure: ModelPackFailure) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(modelPackFailureTitle(failure), systemImage: "xmark.octagon.fill")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.red)
      Text(failure.userSafeReason)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
      if failure.isRetryable {
        Button(String(localized: "Retry download")) {
          startDownload()
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("voicefilter-modelpack-retry")
      }
      Button(String(localized: "Continue without voice filter")) {
        transition(to: .absent)
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("voicefilter-modelpack-continue-without")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("voicefilter-modelpack-failed")
  }

  private func disabledContent(_ pack: InstalledModelPack) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(String(localized: "Pack installed, filter off"), systemImage: "pause.circle")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(
        String(
          localized:
            "The model “\(pack.identifier)” stays on the device. Enable the filter above or delete the pack to free up space."
        )
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      Button(String(localized: "Enable voice filter")) {
        transition(to: .installed(pack))
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("voicefilter-modelpack-enable")
      Button(String(localized: "Delete pack (\(byteString(pack.sizeBytes)))")) {
        Task { await deleteModelPack(pack) }
      }
      .buttonStyle(.bordered)
      .tint(.red)
      .accessibilityIdentifier("voicefilter-modelpack-delete")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("voicefilter-modelpack-disabled")
  }

  @ViewBuilder
  private var crewRosterContent: some View {
    ForEach(Array(crewProfiles.enumerated()), id: \.element.id) { index, profile in
      crewRow(index: index, profile: profile)
    }
    if recordingTarget == .new {
      // why: a transient row for the in-progress new member; the profile only exists once recording
      // succeeds, so until then it has no id to key on.
      crewRow(index: crewProfiles.count, profile: nil)
    }
    Button {
      Task { await toggleEnrollment(target: .new) }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "plus.circle.fill")
        Text(String(localized: "Add crew member"))
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .font(.subheadline.weight(.semibold))
    }
    .buttonStyle(.bordered)
    .tint(.cyan)
    .disabled(!identifierAvailable || recordingTarget != nil)
    .accessibilityIdentifier("voicefilter-add-crew")

    if crewProfiles.isEmpty, recordingTarget == nil {
      Text(
        String(
          localized:
            "No crew voices yet. Add each person on the headset so their transmissions can be told apart from ATC."
        )
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private func crewRow(index: Int, profile: PilotVoiceProfile?) -> some View {
    let target: CrewEnrollmentTarget = profile.map { .existing($0.id) } ?? .new
    let isRecordingThis = recordingTarget == target
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(crewDisplayName(index: index))
          .font(.body.weight(.medium))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
        Text(crewRowSubtitle(isRecording: isRecordingThis))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 4)
      Button(isRecordingThis ? String(localized: "Stop") : String(localized: "Re-record")) {
        Task { await toggleEnrollment(target: target) }
      }
      .buttonStyle(.bordered)
      .tint(isRecordingThis ? .red : nil)
      .disabled(!identifierAvailable || (recordingTarget != nil && !isRecordingThis))
      .accessibilityIdentifier("voicefilter-enroll-crew-\(index)")
      if let profile {
        Button {
          removeCrewMember(id: profile.id)
        } label: {
          Image(systemName: "minus.circle.fill")
            .font(.system(size: 22))
            .foregroundStyle(.red)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(recordingTarget != nil)
        .accessibilityIdentifier("voicefilter-remove-crew-\(index)")
        .accessibilityLabel(String(localized: "Remove \(crewDisplayName(index: index))"))
      }
    }
  }

  private func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  private func acquisitionTitle(_ phase: ModelPackAcquisition.Phase) -> String {
    switch phase {
    case .downloading:
      return String(localized: "Downloading model…")
    case .importing:
      return String(localized: "Installing model…")
    }
  }

  private func modelPackFailureTitle(_ failure: ModelPackFailure) -> String {
    switch failure.kind {
    case .disk:
      return String(localized: "Couldn't delete the model")
    case .corruptState:
      return String(localized: "Model state corrupted")
    case .network, .checksum, .dimensionMismatch, .cancelled, .unknown:
      return String(localized: "Couldn't install the model")
    }
  }
}
