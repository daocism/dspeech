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
  private let matchConfig: SpeakerMatchConfig
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
    matchConfig: SpeakerMatchConfig = .default,
    voiceFilterActive: @escaping @MainActor () -> Bool = { true }
  ) {
    self.identifier = identifier
    self.backendBuilder = backendBuilder
    self.storage = storage
    self.modelPackStorage = modelPackStorage
    self.matchConfig = matchConfig
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
    modelPackState = state
    modelPackStorage.saveState(state)
    // why: identifier is built from the pack state at init; when the state
    // changes at runtime (install/delete/enable) rebuild it via the backend
    // builder so enrollment becomes usable without an app relaunch.
    if let backendBuilder {
      identifier = LocalSpeakerIdentifierFactory.make(
        state: state,
        backendBuilder: backendBuilder
      )
    }
  }

  private func requireInstalledModelPack() throws {
    guard modelPackState.isInstalled else {
      throw LocalSpeakerIdentifierError.modelUnavailable(reason: modelPackState.capabilityReason)
    }
  }

  var enrolledSlots: Set<PilotVoiceProfile.Slot> {
    Set(profiles.map(\.slot))
  }

  func setEnabled(_ flag: Bool) {
    enabled = flag
    storage.saveEnabled(flag)
  }

  func clearStorageIssues() {
    let issues = Set(storageIssues)
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
  }

  func setCallSign(_ raw: String?) {
    if let raw, let parsed = CallSign(raw: raw) {
      callSign = parsed
    } else {
      callSign = nil
    }
    gate.configuredCallSign = callSign
    storage.saveCallSign(callSign)
  }

  func enrollPilot(
    slot: PilotVoiceProfile.Slot,
    label: String,
    samples: [Float],
    sampleRate: Double,
    spokenCallSign rawCallSign: String? = nil
  ) async throws -> PilotVoiceProfile {
    try requireInstalledModelPack()
    let vector = try await identifier.enroll(samples: samples, sampleRate: sampleRate)
    let spokenCallSign = rawCallSign.flatMap(CallSign.init(raw:))
    let profile = PilotVoiceProfile(
      slot: slot,
      label: label,
      voicePrint: vector,
      spokenCallSign: spokenCallSign
    )
    profiles.removeAll { $0.slot == slot }
    profiles.append(profile)
    storage.saveProfiles(profiles)
    if let spokenCallSign {
      callSign = spokenCallSign
      gate.configuredCallSign = spokenCallSign
      storage.saveCallSign(spokenCallSign)
    }
    return profile
  }

  func removePilot(slot: PilotVoiceProfile.Slot) {
    profiles.removeAll { $0.slot == slot }
    storage.saveProfiles(profiles)
  }

  func decide(
    text: String,
    speaker: SpeakerMatchDecision,
    timestamp: Date = .now
  ) -> VoiceFilterDecision {
    let relevance: ATCRelevanceDecision
    let indicator: ATCVoiceIndicator
    if ATCTranscriptGate.containsUrgencyBroadcast(in: text) {
      relevance = gate.evaluate(text: text, speaker: speaker, timestamp: timestamp)
      indicator = Self.indicator(for: speaker, relevance: relevance)
    } else if enabled, voiceFilterActive() {
      relevance = gate.evaluate(text: text, speaker: speaker, timestamp: timestamp)
      indicator = Self.indicator(for: speaker, relevance: relevance)
    } else {
      relevance = .display(reason: .noCallSignConfigured)
      indicator = .filterOff
    }
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
    guard enabled, voiceFilterActive() else { return .transcribe(reason: .filterDisabled) }
    guard !profiles.isEmpty else { return .transcribe(reason: .noPilotProfile) }
    switch speaker {
    case .pilot:
      return .discard(reason: .pilotVoice)
    case .nonPilot:
      return .transcribe(reason: .nonPilotVoice)
    case .mixed:
      return .transcribe(reason: .mixedOrLowConfidence)
    case .insufficientSpeech:
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
      return .nonPilot(bestPilotScore: 0)
    }
    try requireInstalledModelPack()
    return try await identifier.classify(
      samples: samples,
      sampleRate: sampleRate,
      profiles: profiles
    )
  }
}
