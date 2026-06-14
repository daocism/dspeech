import Foundation

enum VoiceFilterCapability: Equatable, Sendable {
  case ready
  case unavailable(reason: String)
}

struct VoiceFilterDecision: Equatable, Sendable {
  let segmentText: String
  let speaker: SpeakerMatchDecision
  let relevance: ATCRelevanceDecision
  let indicator: ATCVoiceIndicator
  let timestamp: Date
}

@MainActor
final class VoiceFilterPipeline {
  private var identifier: any LocalSpeakerIdentifier
  private let backendBuilder: (any LocalSpeakerBackendBuilder)?
  private let storage: VoiceFilterStorage
  private let modelPackStorage: ModelPackStateStorage
  private let voiceFilterActive: @MainActor () -> Bool
  private var gate: ATCTranscriptGate

  private(set) var profiles: [PilotVoiceProfile]
  private(set) var callSign: CallSign?
  private(set) var enabled: Bool
  private(set) var modelPackState: ModelPackState
  private(set) var storageIssues: [VoiceFilterStorageIssue]

  init(
    identifier: any LocalSpeakerIdentifier,
    backendBuilder: (any LocalSpeakerBackendBuilder)? = nil,
    storage: VoiceFilterStorage = UserDefaultsVoiceFilterStorage(),
    modelPackStorage: ModelPackStateStorage = UserDefaultsModelPackStateStorage(),
    voiceFilterActive: @escaping @MainActor () -> Bool = { true }
  ) {
    self.identifier = identifier
    self.backendBuilder = backendBuilder
    self.storage = storage
    self.modelPackStorage = modelPackStorage
    self.voiceFilterActive = voiceFilterActive
    let snapshot = storage.loadSnapshot()
    self.profiles = snapshot.profiles
    self.callSign = snapshot.callSign
    self.enabled = snapshot.enabled
    self.storageIssues = snapshot.issues
    self.modelPackState = modelPackStorage.loadState()
    self.gate = ATCTranscriptGate(
      config: snapshot.gateConfig,
      configuredCallSign: snapshot.callSign
    )
    let modelPackStateName: String
    switch modelPackState {
    case .absent:
      modelPackStateName = "absent"
    case .acquiring(let acquisition):
      modelPackStateName = "acquiring-\(acquisition.phase.rawValue)"
    case .installed:
      modelPackStateName = "installed"
    case .failed(let failure):
      modelPackStateName = "failed-\(failure.kind.rawValue)"
    case .disabled:
      modelPackStateName = "disabled"
    }
    DspeechLog.voiceFilter.info(
      "voice filter pipeline initialized enabled=\(self.enabled, privacy: .public) profiles=\(self.profiles.count, privacy: .public) modelPackState=\(modelPackStateName, privacy: .public) storageIssues=\(self.storageIssues.count, privacy: .public)"
    )
  }

  var capability: VoiceFilterCapability {
    switch identifier.availability {
    case .unavailable(let reason):
      return .unavailable(reason: reason)
    case .available:
      return modelPackState.isInstalled
        ? .ready
        : .unavailable(reason: modelPackState.capabilityReason)
    }
  }

  func setModelPackState(_ state: ModelPackState) {
    let previous = modelPackState
    modelPackState = state
    modelPackStorage.saveState(state)
    let previousName: String
    switch previous {
    case .absent:
      previousName = "absent"
    case .acquiring(let acquisition):
      previousName = "acquiring-\(acquisition.phase.rawValue)"
    case .installed:
      previousName = "installed"
    case .failed(let failure):
      previousName = "failed-\(failure.kind.rawValue)"
    case .disabled:
      previousName = "disabled"
    }
    let newName: String
    switch state {
    case .absent:
      newName = "absent"
    case .acquiring(let acquisition):
      newName = "acquiring-\(acquisition.phase.rawValue)"
    case .installed:
      newName = "installed"
    case .failed(let failure):
      newName = "failed-\(failure.kind.rawValue)"
    case .disabled:
      newName = "disabled"
    }
    DspeechLog.voiceFilter.info(
      "voice filter model-pack state changed from=\(previousName, privacy: .public) to=\(newName, privacy: .public)"
    )
    // why: identifier is built from the pack state at init; when the state
    // changes at runtime (install/delete/enable) rebuild it via the backend
    // builder so enrollment becomes usable without an app relaunch.
    if let backendBuilder {
      identifier = LocalSpeakerIdentifierFactory.make(
        state: state,
        backendBuilder: backendBuilder
      )
      DspeechLog.voiceFilter.info(
        "voice filter identifier rebuilt availability=\(String(describing: self.identifier.availability))"
      )
    }
  }

  private func requireInstalledModelPack() throws {
    guard modelPackState.isInstalled else {
      DspeechLog.voiceFilter.error("voice filter model-pack gate blocked reason=not-installed")
      throw LocalSpeakerIdentifierError.modelUnavailable(reason: modelPackState.capabilityReason)
    }
  }

  func setEnabled(_ flag: Bool) {
    enabled = flag
    storage.saveEnabled(flag)
    DspeechLog.voiceFilter.info("voice filter enabled changed enabled=\(flag, privacy: .public)")
  }

  func clearStorageIssues() {
    let issues = Set(storageIssues)
    DspeechLog.voiceFilter.info(
      "voice filter clearing storage issues count=\(issues.count, privacy: .public)"
    )
    storage.clearCorruptValues(issues)
    if issues.contains(.profilesCorrupted) {
      profiles = []
    }
    if issues.contains(.callSignCorrupted) {
      callSign = nil
      gate.configuredCallSign = nil
    }
    if issues.contains(.gateConfigCorrupted) {
      gate.config = .default
    }
    if issues.contains(.enabledFlagCorrupted) {
      enabled = false
    }
    storageIssues = []
    DspeechLog.voiceFilter.info("voice filter storage issues cleared")
  }

  func setCallSign(_ raw: String?) {
    if let raw, let parsed = CallSign(raw: raw) {
      callSign = parsed
    } else {
      callSign = nil
    }
    gate.configuredCallSign = callSign
    storage.saveCallSign(callSign)
    DspeechLog.voiceFilter.info(
      "voice filter callsign configured=\((self.callSign != nil), privacy: .public)"
    )
  }

  // why: one entry point for both adding a new crew member and re-recording an existing one. When
  // `replacing` names an enrolled profile its voice print is refreshed in place (id + display label
  // preserved); otherwise a new crew member is appended. The roster is variable length — any number
  // of cockpit voices can be enrolled and removed (2026-06-14 request).
  func enrollCrewMember(
    replacing id: UUID? = nil,
    label: String,
    samples: [Float],
    sampleRate: Double,
    spokenCallSign rawCallSign: String? = nil
  ) async throws -> PilotVoiceProfile {
    DspeechLog.voiceFilter.info(
      "crew enrollment requested replacing=\(id != nil, privacy: .public) samples=\(samples.count, privacy: .public) sampleRate=\(sampleRate, privacy: .public)"
    )
    try requireInstalledModelPack()
    let vector: VoicePrintVector
    do {
      vector = try await identifier.enroll(samples: samples, sampleRate: sampleRate)
    } catch {
      DspeechLog.voiceFilter.error(
        "crew enrollment failed error=\(error.localizedDescription)"
      )
      throw error
    }
    let parsedCallSign = rawCallSign.flatMap(CallSign.init(raw:))
    let profile: PilotVoiceProfile
    if let id, let index = profiles.firstIndex(where: { $0.id == id }) {
      let existing = profiles[index]
      profile = PilotVoiceProfile(
        id: existing.id,
        label: existing.label,
        voicePrint: vector,
        spokenCallSign: parsedCallSign ?? existing.spokenCallSign
      )
      profiles[index] = profile
    } else {
      profile = PilotVoiceProfile(label: label, voicePrint: vector, spokenCallSign: parsedCallSign)
      profiles.append(profile)
    }
    storage.saveProfiles(profiles)
    if let parsedCallSign {
      callSign = parsedCallSign
      gate.configuredCallSign = parsedCallSign
      storage.saveCallSign(parsedCallSign)
    }
    DspeechLog.voiceFilter.info(
      "crew enrollment succeeded replaced=\(id != nil, privacy: .public) totalProfiles=\(self.profiles.count, privacy: .public) vectorDimension=\(vector.dimension, privacy: .public)"
    )
    return profile
  }

  func removeCrewMember(id: UUID) {
    profiles.removeAll { $0.id == id }
    storage.saveProfiles(profiles)
    DspeechLog.voiceFilter.info(
      "crew enrollment removed remainingProfiles=\(self.profiles.count, privacy: .public)"
    )
  }

  // why: deleting the model pack must also wipe enrolled voice prints — personal voice data must not
  // survive on disk (and silently return on reinstall) after the user removed the feature that uses
  // it (2026-06-14 audit, privacy/data-retention).
  func removeAllCrewMembers() {
    guard !profiles.isEmpty else { return }
    profiles = []
    storage.deleteAllProfiles()
    DspeechLog.voiceFilter.info("crew enrollment removed all reason=pack-deleted")
  }

  #if DEBUG
    // why: UI-test seam — render the crew roster (name + Re-record + delete rows) in its ENABLED
    // state (available identifier) for the accessibility audit, without a real model or enrollment.
    func seedCrewForTesting(count: Int) {
      identifier = UITestAvailableSpeakerIdentifier()
      profiles = (0..<max(0, count)).map { index in
        var values = [Float](repeating: 0, count: 256)
        values[index % 256] = 1
        return PilotVoiceProfile(
          label: "Crew \(index + 1)",
          voicePrint: VoicePrintVector(values: values, quality: 0.9))
      }
    }
  #endif

  func decide(
    text: String,
    speaker: SpeakerMatchDecision,
    timestamp: Date = .now
  ) -> VoiceFilterDecision {
    let relevance: ATCRelevanceDecision
    let indicator: ATCVoiceIndicator
    // why: an urgency broadcast (mayday/pan-pan) is ALWAYS evaluated and shown, even with the filter
    // off; otherwise the gate runs only when the filter is enabled. Both share the same evaluation.
    if ATCTranscriptGate.containsUrgencyBroadcast(in: text) || enabled {
      relevance = gate.evaluate(text: text, speaker: speaker, timestamp: timestamp)
      indicator = Self.indicator(for: speaker, relevance: relevance)
    } else {
      relevance = .display(reason: .filterDisabled)
      indicator = .filterOff
    }
    let speakerKind: String
    switch speaker {
    case .pilot:
      speakerKind = "pilot"
    case .nonPilot:
      speakerKind = "nonPilot"
    case .mixed:
      speakerKind = "mixed"
    case .insufficientSpeech:
      speakerKind = "insufficientSpeech"
    }
    DspeechLog.voiceFilter.debug(
      "transcript gate decision speaker=\(speakerKind, privacy: .public) relevance=\(String(describing: relevance), privacy: .public) indicator=\(String(describing: indicator), privacy: .public)"
    )
    return VoiceFilterDecision(
      segmentText: text,
      speaker: speaker,
      relevance: relevance,
      indicator: indicator,
      timestamp: timestamp
    )
  }

  func routeBeforeTranscription(
    speaker: SpeakerMatchDecision
  ) -> PreTranscriptionRoutingDecision {
    guard enabled, voiceFilterActive() else {
      DspeechLog.voiceFilter.debug("pre-asr voice filter route=transcribe reason=filterDisabled")
      return .transcribe(reason: .filterDisabled)
    }
    guard !profiles.isEmpty else {
      DspeechLog.voiceFilter.debug("pre-asr voice filter route=transcribe reason=noPilotProfile")
      return .transcribe(reason: .noPilotProfile)
    }
    switch speaker {
    case .pilot:
      DspeechLog.voiceFilter.debug("pre-asr voice filter route=transcribe reason=pilotVoice")
      return .transcribe(reason: .pilotVoice)
    case .nonPilot:
      DspeechLog.voiceFilter.debug("pre-asr voice filter route=transcribe reason=nonPilotVoice")
      return .transcribe(reason: .nonPilotVoice)
    case .mixed:
      DspeechLog.voiceFilter.debug(
        "pre-asr voice filter route=transcribe reason=mixedOrLowConfidence"
      )
      return .transcribe(reason: .mixedOrLowConfidence)
    case .insufficientSpeech:
      DspeechLog.voiceFilter.debug(
        "pre-asr voice filter route=transcribe reason=insufficientSpeech"
      )
      return .transcribe(reason: .insufficientSpeech)
    }
  }

  private static func indicator(
    for speaker: SpeakerMatchDecision,
    relevance: ATCRelevanceDecision
  ) -> ATCVoiceIndicator {
    if case .display(reason: .urgencyBroadcast) = relevance { return .urgencyBroadcast }
    if case .pilot = speaker { return .pilotSuppressed }
    if case .insufficientSpeech = speaker { return .noiseOrTooShortSuppressed }
    if case .mixed = speaker { return .mixedSpeakerCandidate }

    switch relevance {
    case .display(reason: .callSignMatch):
      return .dispatcherAddressedOwnCallSign
    case .display(reason: .continuationOfRecentHit),
      .holdContinuation(reason: .continuationOfRecentHit):
      return .dispatcherContinuation
    case .display(reason: .noCallSignConfigured):
      return .probableDispatcher
    case .display(reason: .insufficientSpeech):
      return .noiseOrTooShortSuppressed
    case .suppress(reason: .addressedToOther), .suppress(reason: .nonRelevant):
      return .otherTrafficSuppressed
    case .suppress(reason: .insufficientSpeech):
      return .noiseOrTooShortSuppressed
    case .suppress(reason: .pilotReadback):
      return .pilotSuppressed
    case .display(reason: .filterDisabled):
      return .filterOff
    case .display(reason: _), .holdContinuation(reason: _):
      return .probableDispatcher
    case .suppress(reason: _):
      return .otherTrafficSuppressed
    }
  }

  func classify(
    samples: [Float],
    sampleRate: Double
  ) async throws -> SpeakerMatchDecision {
    guard enabled, voiceFilterActive(), !profiles.isEmpty else {
      DspeechLog.voiceFilter.debug(
        "speaker classification skipped reason=filter-disabled-or-no-profile"
      )
      return .nonPilot(bestPilotScore: 0)
    }
    try requireInstalledModelPack()
    do {
      let decision = try await identifier.classify(
        samples: samples,
        sampleRate: sampleRate,
        profiles: profiles
      )
      let decisionKind: String
      switch decision {
      case .pilot:
        decisionKind = "pilot"
      case .nonPilot:
        decisionKind = "nonPilot"
      case .mixed:
        decisionKind = "mixed"
      case .insufficientSpeech:
        decisionKind = "insufficientSpeech"
      }
      DspeechLog.voiceFilter.debug(
        "speaker classification succeeded decision=\(decisionKind, privacy: .public)"
      )
      return decision
    } catch {
      DspeechLog.voiceFilter.error(
        "speaker classification failed error=\(error.localizedDescription)"
      )
      throw error
    }
  }
}

#if DEBUG
  // why: UI-test-only available identifier so the crew roster renders ENABLED for the accessibility
  // audit (the real FluidAudio identifier is unavailable on the Simulator). Never used in Release.
  private struct UITestAvailableSpeakerIdentifier: LocalSpeakerIdentifier {
    let availability: LocalSpeakerIdentifierAvailability = .available
    let embeddingDimension = 256
    func enroll(samples: [Float], sampleRate: Double) async throws -> VoicePrintVector {
      VoicePrintVector(values: Array(repeating: Float(0.1), count: 256), quality: 0.9)
    }
    func classify(
      samples: [Float], sampleRate: Double, profiles: [PilotVoiceProfile]
    ) async throws -> SpeakerMatchDecision {
      .nonPilot(bestPilotScore: 0)
    }
  }
#endif
