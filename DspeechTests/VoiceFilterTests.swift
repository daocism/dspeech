import AVFoundation
import CryptoKit
import Foundation
import Testing

@testable import Dspeech

struct SpeakerMatcherTests {
  private static func vector(_ values: [Float], quality: Float = 0.9) -> VoicePrintVector {
    VoicePrintVector(values: values, quality: quality)
  }

  private static func profile(
    _ slot: PilotVoiceProfile.Slot,
    _ values: [Float]
  ) -> PilotVoiceProfile {
    PilotVoiceProfile(
      id: UUID(),
      slot: slot,
      label: slot == .primary ? "Captain" : "First Officer",
      voicePrint: vector(values),
      enrolledAt: Date(timeIntervalSince1970: 0)
    )
  }

  private static func unitVector(cosineAgainstXAxis score: Float) -> [Float] {
    [score, (1 - score * score).squareRoot()]
  }

  @Test func cosineSimilarityIdentical() {
    let a: [Float] = [1, 2, 3, 4]
    #expect(abs(SpeakerMatcher.cosineSimilarity(a, a) - 1.0) < 1e-5)
  }

  @Test func cosineSimilarityOrthogonal() {
    #expect(abs(SpeakerMatcher.cosineSimilarity([1, 0, 0, 0], [0, 1, 0, 0])) < 1e-5)
  }

  @Test func cosineSimilarityOpposite() {
    #expect(SpeakerMatcher.cosineSimilarity([1, 1, 1, 1], [-1, -1, -1, -1]) < -0.99)
  }

  @Test func cosineSimilarityMismatchedLength() {
    #expect(SpeakerMatcher.cosineSimilarity([1, 2], [1, 2, 3]) == 0)
    #expect(SpeakerMatcher.cosineSimilarity([], []) == 0)
  }

  @Test func insufficientSpeechBelowQualityFloor() {
    let cand = Self.vector([1, 0, 0, 0], quality: 0.1)
    let decision = SpeakerMatcher.match(
      candidate: cand,
      profiles: [Self.profile(.primary, [1, 0, 0, 0])]
    )
    #expect(decision == .insufficientSpeech)
  }

  @Test func emptyVectorIsInsufficient() {
    let cand = VoicePrintVector(values: [], quality: 1.0)
    #expect(SpeakerMatcher.match(candidate: cand, profiles: []) == .insufficientSpeech)
  }

  @Test func nonPilotWhenNoProfiles() {
    let decision = SpeakerMatcher.match(candidate: Self.vector([1, 0, 0, 0]), profiles: [])
    if case .nonPilot(let score) = decision {
      #expect(score == 0)
    } else {
      Issue.record("expected nonPilot, got \(decision)")
    }
  }

  @Test func onePilotAboveThresholdMatches() {
    let cand = Self.vector([0.95, 0.31, 0, 0])
    let profiles = [Self.profile(.primary, [1, 0.3, 0, 0])]
    let decision = SpeakerMatcher.match(candidate: cand, profiles: profiles)
    if case .pilot(let slot, let score) = decision {
      #expect(slot == .primary)
      #expect(score > 0.99)
    } else {
      Issue.record("expected pilot, got \(decision)")
    }
  }

  @Test func pilotThresholdBoundaryReturnsPilotWhenSeparated() {
    let config = SpeakerMatchConfig.default
    let cand = Self.vector(Self.unitVector(cosineAgainstXAxis: config.pilotMatchThreshold))
    let profiles = [
      Self.profile(.primary, [1, 0]),
      Self.profile(.secondary, [-1, 0]),
    ]

    let decision = SpeakerMatcher.match(candidate: cand, profiles: profiles, config: config)
    if case .pilot(let slot, _) = decision {
      #expect(slot == .primary)
    } else {
      Issue.record("expected pilot at threshold boundary, got \(decision)")
    }
  }

  @Test func onePilotBelowThresholdIsNonPilot() {
    let cand = Self.vector([0.2, 1.0, 0, 0])
    let profiles = [Self.profile(.primary, [1.0, 0.1, 0, 0])]
    let decision = SpeakerMatcher.match(candidate: cand, profiles: profiles)
    if case .nonPilot(let score) = decision {
      #expect(score < 0.72)
    } else {
      Issue.record("expected nonPilot, got \(decision)")
    }
  }

  @Test func mixedLowerBoundBoundaryReturnsMixedBelowPilotThreshold() {
    let config = SpeakerMatchConfig.default
    let cand = Self.vector(Self.unitVector(cosineAgainstXAxis: config.mixedSpeakerLowerBound))
    let profiles = [Self.profile(.primary, [1, 0])]

    let decision = SpeakerMatcher.match(candidate: cand, profiles: profiles, config: config)
    if case .mixed(let score) = decision {
      #expect(score < config.pilotMatchThreshold)
    } else {
      Issue.record("expected mixed at lower-bound boundary, got \(decision)")
    }
  }

  @Test func twoPilotMatchesClosestSlot() {
    let cand = Self.vector([0, 1.0, 0.05, 0])
    let profiles = [
      Self.profile(.primary, [1, 0, 0, 0]),
      Self.profile(.secondary, [0, 1, 0, 0]),
    ]
    let decision = SpeakerMatcher.match(candidate: cand, profiles: profiles)
    if case .pilot(let slot, _) = decision {
      #expect(slot == .secondary)
    } else {
      Issue.record("expected secondary pilot, got \(decision)")
    }
  }

  @Test func twoPilotAmbiguousFallsBackToMixedCandidate() {
    let cand = Self.vector([0.71, 0.71, 0, 0])
    let profiles = [
      Self.profile(.primary, [1, 0, 0, 0]),
      Self.profile(.secondary, [0, 1, 0, 0]),
    ]
    let decision = SpeakerMatcher.match(candidate: cand, profiles: profiles)
    if case .mixed(let score) = decision {
      #expect(score > 0.6)
    } else {
      Issue.record("expected mixed ambiguous candidate, got \(decision)")
    }
  }

  @Test func separationMarginBoundaryIsInclusive() {
    let config = SpeakerMatchConfig.default
    let cand = Self.vector([1, 0])
    let primary = Self.profile(.primary, [1, 0])
    let secondaryAtMargin = Self.profile(
      .secondary,
      Self.unitVector(cosineAgainstXAxis: 1 - config.separationMargin)
    )
    let secondaryInsideMargin = Self.profile(
      .secondary,
      Self.unitVector(cosineAgainstXAxis: 1 - config.separationMargin / 2)
    )

    let atMargin = SpeakerMatcher.match(
      candidate: cand,
      profiles: [primary, secondaryAtMargin],
      config: config
    )
    if case .pilot(let slot, _) = atMargin {
      #expect(slot == .primary)
    } else {
      Issue.record("expected pilot at separation-margin boundary, got \(atMargin)")
    }

    let insideMargin = SpeakerMatcher.match(
      candidate: cand,
      profiles: [primary, secondaryInsideMargin],
      config: config
    )
    if case .mixed(let score) = insideMargin {
      #expect(score >= config.pilotMatchThreshold)
    } else {
      Issue.record("expected mixed inside separation margin, got \(insideMargin)")
    }
  }

  @Test func dimensionMismatchProfileIsSkipped() {
    let cand = Self.vector([1, 0, 0, 0])
    let wrong = PilotVoiceProfile(
      slot: .primary,
      label: "wrong-dim",
      voicePrint: VoicePrintVector(values: [1, 0], quality: 0.9)
    )
    let decision = SpeakerMatcher.match(candidate: cand, profiles: [wrong])
    #expect(decision == .nonPilot(bestPilotScore: 0))
  }
}

struct VoiceFilterStorageTests {
  private func makeStore() -> (UserDefaultsVoiceFilterStorage, () -> Void) {
    let suiteName = "dspeech.tests.voicefilter.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let cleanup = { defaults.removePersistentDomain(forName: suiteName) }
    return (UserDefaultsVoiceFilterStorage(defaults: defaults), cleanup)
  }

  @Test func emptyDefaults() {
    let (store, cleanup) = makeStore()
    defer { cleanup() }
    #expect(store.loadProfiles().isEmpty)
    #expect(store.loadCallSign() == nil)
    #expect(store.loadEnabled() == false)
    #expect(store.loadGateConfig() == .default)
  }

  @Test func profilesRoundTrip() {
    let (store, cleanup) = makeStore()
    defer { cleanup() }
    let profile = PilotVoiceProfile(
      slot: .primary,
      label: "Captain",
      voicePrint: VoicePrintVector(values: [0.1, 0.2, 0.3, 0.4], quality: 0.83),
      enrolledAt: Date(timeIntervalSince1970: 748_137_600)
    )
    store.saveProfiles([profile])
    let loaded = store.loadProfiles()
    #expect(loaded.count == 1)
    #expect(loaded.first?.slot == .primary)
    #expect(loaded.first?.label == "Captain")
    #expect(loaded.first?.voicePrint.values == [0.1, 0.2, 0.3, 0.4])
  }

  @Test func callSignRoundTripAndClear() {
    let (store, cleanup) = makeStore()
    defer { cleanup() }
    let cs = CallSign(raw: "N123AB")!
    store.saveCallSign(cs)
    #expect(store.loadCallSign() == cs)
    store.saveCallSign(nil)
    #expect(store.loadCallSign() == nil)
  }
}

struct ATCTranscriptGateTests {
  private let t0 = Date(timeIntervalSince1970: 0)

  @Test func noCallSignDisplaysAllNonPilotSegments() {
    var gate = ATCTranscriptGate()
    let dec = gate.evaluate(
      text: "United 247 contact ground point niner",
      speaker: .nonPilot(bestPilotScore: 0.1),
      timestamp: t0
    )
    #expect(dec == .display(reason: .noCallSignConfigured))
  }

  @Test func pilotReadbackContainingCallSignIsSuppressed() {
    var gate = ATCTranscriptGate(configuredCallSign: CallSign(raw: "N123AB"))
    let dec = gate.evaluate(
      text: "N123AB descending two thousand",
      speaker: .pilot(slot: .primary, score: 0.91),
      timestamp: t0
    )
    #expect(dec == .suppress(reason: .pilotReadback))
  }

  @Test func nonPilotWithCallSignMatchDisplays() {
    var gate = ATCTranscriptGate(configuredCallSign: CallSign(raw: "N123AB"))
    let dec = gate.evaluate(
      text: "N123AB descend and maintain three thousand",
      speaker: .nonPilot(bestPilotScore: 0.05),
      timestamp: t0
    )
    #expect(dec == .display(reason: .callSignMatch))
  }

  @Test func continuationWithinWindowDisplays() {
    var gate = ATCTranscriptGate(configuredCallSign: CallSign(raw: "N123AB"))
    _ = gate.evaluate(
      text: "N123AB contact tower one one eight decimal three",
      speaker: .nonPilot(bestPilotScore: 0.05),
      timestamp: t0
    )
    let cont = gate.evaluate(
      text: "expedite if able",
      speaker: .nonPilot(bestPilotScore: 0.05),
      timestamp: t0.addingTimeInterval(3)
    )
    #expect(cont == .display(reason: .continuationOfRecentHit))
  }

  @Test func nonPilotWithoutCallSignAndExpiredWindowSuppresses() {
    var gate = ATCTranscriptGate(configuredCallSign: CallSign(raw: "N123AB"))
    let dec = gate.evaluate(
      text: "United 247 turn right heading two seven zero",
      speaker: .nonPilot(bestPilotScore: 0.05),
      timestamp: t0
    )
    #expect(dec == .suppress(reason: .nonRelevant))
  }

  @Test func addressedToOtherDetectorSuppresses() {
    let detector: @Sendable (String) -> Bool = { $0.uppercased().contains("UNITED 247") }
    var gate = ATCTranscriptGate(
      configuredCallSign: CallSign(raw: "N123AB"),
      otherCallSignDetector: detector
    )
    let dec = gate.evaluate(
      text: "United 247 cleared visual approach",
      speaker: .nonPilot(bestPilotScore: 0.05),
      timestamp: t0
    )
    #expect(dec == .suppress(reason: .addressedToOther))
  }

  @Test func insufficientSpeechIsSuppressed() {
    var gate = ATCTranscriptGate(configuredCallSign: CallSign(raw: "N123AB"))
    let dec = gate.evaluate(text: "anything", speaker: .insufficientSpeech, timestamp: t0)
    #expect(dec == .suppress(reason: .insufficientSpeech))
  }
}

@MainActor
struct VoiceFilterPipelineTests {
  final class InMemoryStorage: VoiceFilterStorage, @unchecked Sendable {
    var profiles: [PilotVoiceProfile] = []
    var callSign: CallSign?
    var config: ATCTranscriptGateConfig = .default
    var enabled: Bool = false

    func loadProfiles() -> [PilotVoiceProfile] { profiles }
    func saveProfiles(_ profiles: [PilotVoiceProfile]) { self.profiles = profiles }
    func loadCallSign() -> CallSign? { callSign }
    func saveCallSign(_ cs: CallSign?) { callSign = cs }
    func loadGateConfig() -> ATCTranscriptGateConfig { config }
    func saveGateConfig(_ c: ATCTranscriptGateConfig) { config = c }
    func loadEnabled() -> Bool { enabled }
    func saveEnabled(_ flag: Bool) { enabled = flag }
  }

  final class InMemoryModelPackStorage: ModelPackStateStorage, @unchecked Sendable {
    var state: ModelPackState
    init(_ state: ModelPackState = .absent) { self.state = state }
    func loadState() -> ModelPackState { state }
    func saveState(_ state: ModelPackState) { self.state = state }
  }

  static func installedPack() -> InstalledModelPack {
    InstalledModelPack(
      identifier: "fluidaudio-speaker-256",
      version: "1.0.0",
      embeddingDimension: 256,
      checksumSHA256: String(repeating: "a", count: 64),
      source: "https://mirror.invalid/voice-filter",
      sizeBytes: 12_345_678,
      installedAt: Date(timeIntervalSince1970: 748_137_600)
    )
  }

  struct FakeIdentifier: LocalSpeakerIdentifier {
    let vector: VoicePrintVector
    var availability: LocalSpeakerIdentifierAvailability { .available }
    var embeddingDimension: Int { vector.dimension }

    func enroll(samples: [Float], sampleRate: Double) async throws -> VoicePrintVector {
      _ = samples
      _ = sampleRate
      return vector
    }

    func classify(
      samples: [Float],
      sampleRate: Double,
      profiles: [PilotVoiceProfile]
    ) async throws -> SpeakerMatchDecision {
      _ = samples
      _ = sampleRate
      return SpeakerMatcher.match(candidate: vector, profiles: profiles)
    }
  }

  @Test func unavailableIdentifierSurfacesCapability() {
    let pipeline = VoiceFilterPipeline(
      identifier: UnavailableLocalSpeakerIdentifier(reason: "test-blocker"),
      storage: InMemoryStorage()
    )
    if case .unavailable(let reason) = pipeline.capability {
      #expect(reason == "test-blocker")
    } else {
      Issue.record("expected unavailable capability")
    }
  }

  @Test func enrollThrowsWhenIdentifierUnavailable() async {
    let pipeline = VoiceFilterPipeline(
      identifier: UnavailableLocalSpeakerIdentifier(),
      storage: InMemoryStorage()
    )
    pipeline.setEnabled(true)
    do {
      _ = try await pipeline.enrollPilot(
        slot: .primary,
        label: "Captain",
        samples: [0, 1, 0, 1],
        sampleRate: 16_000
      )
      Issue.record("expected throw")
    } catch let err as LocalSpeakerIdentifierError {
      if case .modelUnavailable = err {
      } else {
        Issue.record("expected modelUnavailable, got \(err)")
      }
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }

  @Test func decideRespectsDisabledFlag() {
    let store = InMemoryStorage()
    store.callSign = CallSign(raw: "N123AB")
    let pipeline = VoiceFilterPipeline(
      identifier: UnavailableLocalSpeakerIdentifier(),
      storage: store
    )
    pipeline.setEnabled(false)
    let dec = pipeline.decide(
      text: "United 247 cleared",
      speaker: .nonPilot(bestPilotScore: 0.1),
      timestamp: Date(timeIntervalSince1970: 0)
    )
    if case .display(let reason) = dec.relevance {
      #expect(reason == .noCallSignConfigured)
    } else {
      Issue.record("disabled pipeline should display by default, got \(dec.relevance)")
    }
  }

  @Test func decideUsesGateWhenEnabled() {
    let store = InMemoryStorage()
    store.callSign = CallSign(raw: "N123AB")
    store.enabled = true
    let pipeline = VoiceFilterPipeline(
      identifier: UnavailableLocalSpeakerIdentifier(),
      storage: store
    )
    let dec = pipeline.decide(
      text: "Tower N123AB position and hold",
      speaker: .nonPilot(bestPilotScore: 0.1),
      timestamp: Date(timeIntervalSince1970: 0)
    )
    if case .display(let reason) = dec.relevance {
      #expect(reason == .callSignMatch)
      #expect(dec.indicator == .dispatcherAddressedOwnCallSign)
    } else {
      Issue.record("expected callSignMatch display, got \(dec.relevance)")
    }
  }

  @Test func routeBeforeTranscriptionDiscardsPilotBeforeSTT() {
    let store = InMemoryStorage()
    store.enabled = true
    store.profiles = [
      PilotVoiceProfile(
        slot: .primary,
        label: "Captain",
        voicePrint: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.9)
      )
    ]
    let pipeline = VoiceFilterPipeline(
      identifier: UnavailableLocalSpeakerIdentifier(),
      storage: store
    )
    let route = pipeline.routeBeforeTranscription(
      speaker: .pilot(slot: .primary, score: 0.91)
    )
    #expect(route == .discard(reason: .pilotVoice))
  }

  @Test func routeBeforeTranscriptionKeepsMixedSegmentsVisible() {
    let store = InMemoryStorage()
    store.enabled = true
    store.profiles = [
      PilotVoiceProfile(
        slot: .primary,
        label: "Captain",
        voicePrint: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.9)
      )
    ]
    let pipeline = VoiceFilterPipeline(
      identifier: UnavailableLocalSpeakerIdentifier(),
      storage: store
    )
    let route = pipeline.routeBeforeTranscription(speaker: .mixed(bestPilotScore: 0.68))
    #expect(route == .transcribe(reason: .mixedOrLowConfidence))
  }

  @Test func enrollmentStoresPilotVoiceAndSpokenCallSign() async throws {
    let store = InMemoryStorage()
    let pipeline = VoiceFilterPipeline(
      identifier: FakeIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.92)),
      storage: store,
      modelPackStorage: InMemoryModelPackStorage(.installed(Self.installedPack()))
    )
    let profile = try await pipeline.enrollPilot(
      slot: .primary,
      label: "Captain",
      samples: [0, 1, 0, 1],
      sampleRate: 16_000,
      spokenCallSign: "N-123-AB"
    )
    #expect(profile.spokenCallSign?.normalized == "N123AB")
    #expect(store.profiles.first?.spokenCallSign?.normalized == "N123AB")
    #expect(store.callSign?.normalized == "N123AB")
  }

  @Test func absentPackMakesAvailableIdentifierUnavailable() {
    let pipeline = VoiceFilterPipeline(
      identifier: FakeIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.92)),
      storage: InMemoryStorage(),
      modelPackStorage: InMemoryModelPackStorage(.absent)
    )
    if case .unavailable = pipeline.capability {
    } else {
      Issue.record("expected unavailable capability when pack absent, got \(pipeline.capability)")
    }
  }

  @Test func absentPackEnrollThrowsModelUnavailable() async {
    let pipeline = VoiceFilterPipeline(
      identifier: FakeIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.92)),
      storage: InMemoryStorage(),
      modelPackStorage: InMemoryModelPackStorage(.absent)
    )
    do {
      _ = try await pipeline.enrollPilot(
        slot: .primary,
        label: "Captain",
        samples: [0, 1, 0, 1],
        sampleRate: 16_000
      )
      Issue.record("expected enroll to throw with absent pack")
    } catch let err as LocalSpeakerIdentifierError {
      if case .modelUnavailable = err {
      } else {
        Issue.record("expected modelUnavailable, got \(err)")
      }
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }

  @Test func absentPackClassifyThrowsModelUnavailable() async {
    let store = InMemoryStorage()
    store.enabled = true
    store.profiles = [
      PilotVoiceProfile(
        slot: .primary,
        label: "Captain",
        voicePrint: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.9)
      )
    ]
    let pipeline = VoiceFilterPipeline(
      identifier: FakeIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.92)),
      storage: store,
      modelPackStorage: InMemoryModelPackStorage(.absent)
    )
    do {
      _ = try await pipeline.classify(samples: [0, 1, 0, 1], sampleRate: 16_000)
      Issue.record("expected classify to throw with absent pack")
    } catch let err as LocalSpeakerIdentifierError {
      if case .modelUnavailable = err {
      } else {
        Issue.record("expected modelUnavailable, got \(err)")
      }
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }

  @Test func installedPackMakesCapabilityReady() {
    let pipeline = VoiceFilterPipeline(
      identifier: FakeIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.92)),
      storage: InMemoryStorage(),
      modelPackStorage: InMemoryModelPackStorage(.installed(Self.installedPack()))
    )
    #expect(pipeline.capability == .ready)
  }

  @Test func installedPackClassifyDelegatesToIdentifier() async throws {
    let store = InMemoryStorage()
    store.enabled = true
    store.profiles = [
      PilotVoiceProfile(
        slot: .primary,
        label: "Captain",
        voicePrint: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.9)
      )
    ]
    let pipeline = VoiceFilterPipeline(
      identifier: FakeIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.92)),
      storage: store,
      modelPackStorage: InMemoryModelPackStorage(.installed(Self.installedPack()))
    )
    let decision = try await pipeline.classify(samples: [0, 1, 0, 1], sampleRate: 16_000)
    if case .pilot(let slot, _) = decision {
      #expect(slot == .primary)
    } else {
      Issue.record("expected delegated pilot decision, got \(decision)")
    }
  }

  @Test func voiceFilterActiveKillSwitchDisablesTextAndPreASRFiltering() async throws {
    let store = InMemoryStorage()
    store.enabled = true
    store.callSign = CallSign(raw: "N123AB")
    store.profiles = [
      PilotVoiceProfile(
        slot: .primary,
        label: "Captain",
        voicePrint: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.9)
      )
    ]
    let pipeline = VoiceFilterPipeline(
      identifier: FakeIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.92)),
      storage: store,
      modelPackStorage: InMemoryModelPackStorage(.installed(Self.installedPack())),
      voiceFilterActive: { false }
    )

    let textDecision = pipeline.decide(
      text: "United 247 cleared",
      speaker: .pilot(slot: .primary, score: 0.99),
      timestamp: Date(timeIntervalSince1970: 0)
    )
    #expect(textDecision.relevance == .display(reason: .noCallSignConfigured))
    #expect(textDecision.indicator == .filterOff)

    let speaker = try await pipeline.classify(samples: [0.1, 0.2], sampleRate: 16_000)
    #expect(speaker == .nonPilot(bestPilotScore: 0))
    #expect(
      pipeline.routeBeforeTranscription(speaker: .pilot(slot: .primary, score: 0.99))
        == .transcribe(reason: .filterDisabled)
    )
  }

  @Test func disabledPackEnrollThrowsDespitePackMetadata() async {
    let pipeline = VoiceFilterPipeline(
      identifier: FakeIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.92)),
      storage: InMemoryStorage(),
      modelPackStorage: InMemoryModelPackStorage(.disabled(Self.installedPack()))
    )
    if case .unavailable = pipeline.capability {
    } else {
      Issue.record("disabled pack must report unavailable, got \(pipeline.capability)")
    }
    do {
      _ = try await pipeline.enrollPilot(
        slot: .primary,
        label: "Captain",
        samples: [0, 1, 0, 1],
        sampleRate: 16_000
      )
      Issue.record("expected enroll to throw with disabled pack")
    } catch let err as LocalSpeakerIdentifierError {
      if case .modelUnavailable = err {
      } else {
        Issue.record("expected modelUnavailable, got \(err)")
      }
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }

  @Test func disabledPackClassifyThrowsDespitePackMetadata() async {
    let store = InMemoryStorage()
    store.enabled = true
    store.profiles = [
      PilotVoiceProfile(
        slot: .primary,
        label: "Captain",
        voicePrint: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.9)
      )
    ]
    let pipeline = VoiceFilterPipeline(
      identifier: FakeIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.92)),
      storage: store,
      modelPackStorage: InMemoryModelPackStorage(.disabled(Self.installedPack()))
    )
    do {
      _ = try await pipeline.classify(samples: [0, 1, 0, 1], sampleRate: 16_000)
      Issue.record("expected classify to throw with disabled pack")
    } catch let err as LocalSpeakerIdentifierError {
      if case .modelUnavailable = err {
      } else {
        Issue.record("expected modelUnavailable, got \(err)")
      }
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }
}

struct ModelPackStateStorageTests {
  private func makeStore() -> (UserDefaultsModelPackStateStorage, () -> Void) {
    let suiteName = "dspeech.tests.modelpack.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let cleanup = { defaults.removePersistentDomain(forName: suiteName) }
    return (UserDefaultsModelPackStateStorage(defaults: defaults), cleanup)
  }

  private static func pack() -> InstalledModelPack {
    InstalledModelPack(
      identifier: "fluidaudio-speaker-256",
      version: "1.0.0",
      embeddingDimension: 256,
      checksumSHA256: String(repeating: "a", count: 64),
      source: "https://mirror.invalid/voice-filter",
      sizeBytes: 12_345_678,
      installedAt: Date(timeIntervalSince1970: 748_137_600)
    )
  }

  @Test func roundTripAbsent() {
    let (store, cleanup) = makeStore()
    defer { cleanup() }
    store.saveState(.absent)
    #expect(store.loadState() == .absent)
  }

  @Test func roundTripInstalled() {
    let (store, cleanup) = makeStore()
    defer { cleanup() }
    store.saveState(.installed(Self.pack()))
    #expect(store.loadState() == .installed(Self.pack()))
  }

  @Test func roundTripFailed() {
    let (store, cleanup) = makeStore()
    defer { cleanup() }
    let failure = ModelPackFailure(
      kind: .checksum,
      userSafeReason: "Проверка контрольной суммы не прошла.",
      isRetryable: true
    )
    store.saveState(.failed(failure))
    #expect(store.loadState() == .failed(failure))
  }

  @Test func roundTripDisabled() {
    let (store, cleanup) = makeStore()
    defer { cleanup() }
    store.saveState(.disabled(Self.pack()))
    #expect(store.loadState() == .disabled(Self.pack()))
  }

  @Test func acquiringRecoversToAbsentOnColdStart() {
    let (store, cleanup) = makeStore()
    defer { cleanup() }
    store.saveState(.acquiring(ModelPackAcquisition(phase: .downloading, fractionComplete: 0.4)))
    #expect(store.loadState() == .absent)
  }

  @Test func missingDataLoadsAbsent() {
    let (store, cleanup) = makeStore()
    defer { cleanup() }
    #expect(store.loadState() == .absent)
  }

  @Test func corruptDataLoadsAbsent() {
    let suiteName = "dspeech.tests.modelpack.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(
      Data([0x00, 0x01, 0x02, 0x03]), forKey: UserDefaultsModelPackStateStorage.stateKey)
    let store = UserDefaultsModelPackStateStorage(defaults: defaults)
    #expect(store.loadState() == .absent)
  }

  @Test func launchArgumentFailedRetryableLoadsFailedState() {
    let suiteName = "dspeech.tests.modelpack.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("failedRetryable", forKey: UserDefaultsModelPackStateStorage.stateKey)
    let store = UserDefaultsModelPackStateStorage(defaults: defaults)
    let state = store.loadState()
    guard case .failed(let failure) = state else {
      Issue.record("expected failed state from launch argument, got \(state)")
      return
    }
    #expect(failure.isRetryable)
  }

  @Test func launchArgumentAcquiringHalfLoadsAcquiringProgress() {
    let suiteName = "dspeech.tests.modelpack.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("acquiringHalf", forKey: UserDefaultsModelPackStateStorage.stateKey)
    let store = UserDefaultsModelPackStateStorage(defaults: defaults)
    let state = store.loadState()
    guard case .acquiring(let acquisition) = state else {
      Issue.record("expected acquiring state from launch argument, got \(state)")
      return
    }
    #expect(acquisition.percentComplete == 42)
  }
}

struct ModelPackDownloadFailureTests {
  @Test func integrityInstallErrorsProduceChecksumFailure() {
    let errors: [ModelPackInstallError] = [
      .integrityExpectedFileMissing("model.bin"),
      .integrityUnexpectedFile("extra.bin"),
      .integrityChecksumMismatch(
        relativePath: "model.bin", expectedSHA256: "expected", actualSHA256: "actual"),
      .integrityFileUnreadable("model.bin"),
      .integrityManifestEmpty,
    ]

    for error in errors {
      let failure = modelPackDownloadFailure(for: error)
      #expect(failure.kind == .checksum)
      #expect(failure.isRetryable)
      #expect(failure.userSafeReason.contains("контрольной суммы"))
      #expect(failure.userSafeReason.contains("целостности"))
    }
  }

  @Test func otherDownloadErrorsProduceNetworkFailure() {
    let failures = [
      modelPackDownloadFailure(for: ModelPackInstallError.filesMissingAfterDownload),
      modelPackDownloadFailure(for: URLError(.notConnectedToInternet)),
    ]

    for failure in failures {
      #expect(failure.kind == .network)
      #expect(failure.isRetryable)
      #expect(failure.userSafeReason.contains("сети"))
    }
  }
}

struct SpeakerModelPackInstallerTests {
  private static let segmentationFixturePath = "pyannote_segmentation.mlmodelc/model.mil"
  private static let embeddingFixturePath = "wespeaker_v2.mlmodelc/model.mil"

  @Test func productionManifestPinsFluidAudioModelFiles() {
    let manifest = Dictionary(
      uniqueKeysWithValues: SpeakerModelPackInstaller.expectedModelFileManifest.map {
        ($0.relativePath, $0.sha256)
      })

    #expect(manifest.count == 10)
    #expect(
      manifest["pyannote_segmentation.mlmodelc/analytics/coremldata.bin"]
        == "b379db0541b35344a34bb7540783ae704c11599bbed5aa8bbbda11c20ad215ee"
    )
    #expect(
      manifest["pyannote_segmentation.mlmodelc/coremldata.bin"]
        == "4a450ea1b053b9eb7eef0cab6971018076600840c7e246d064e7c5387f456c98"
    )
    #expect(
      manifest["pyannote_segmentation.mlmodelc/metadata.json"]
        == "44e1fa36d6abafacf688beccad99f7569394248d8bb41545829997c67668c08c"
    )
    #expect(
      manifest["pyannote_segmentation.mlmodelc/model.mil"]
        == "97f2dec6f83e80bf4247b98e13c2dde19f92c05820ef08068bbf554488d70bdd"
    )
    #expect(
      manifest["pyannote_segmentation.mlmodelc/weights/weight.bin"]
        == "0266f4ad4d843ecf31ef9220ad6b80616b3ec64a4404b64f3ea0371554e236ec"
    )
    #expect(
      manifest["wespeaker_v2.mlmodelc/analytics/coremldata.bin"]
        == "d2b1fcde6121aea3ff0e14c1dc50d09dacb0314a2e89156353c31804230a422f"
    )
    #expect(
      manifest["wespeaker_v2.mlmodelc/coremldata.bin"]
        == "6feb2472a71fa9d8a84020c85206138a4f6261c565c9884bf518d59dd5838da7"
    )
    #expect(
      manifest["wespeaker_v2.mlmodelc/metadata.json"]
        == "ddc4858b4051254098015cd0b97080149839d697faf7b036f933190e70b26758"
    )
    #expect(
      manifest["wespeaker_v2.mlmodelc/model.mil"]
        == "2850f775d6ba659f01f616fed77ce6a45a25de3eb7e4bf3a4b07b658be4e13dd"
    )
    #expect(
      manifest["wespeaker_v2.mlmodelc/weights/weight.bin"]
        == "34004f6798d35cad7071e2fdc67e63faaa782f53697e1cb49bcb452cf81ae151"
    )
  }

  @Test func verifierAcceptsExactManifestBytes() throws {
    let contents = Self.validFixtureContents()
    let root = try Self.makeFixture(contents)
    defer { Self.removeFixture(root) }

    let verified = try SpeakerModelPackInstaller.verifyModelPack(
      at: root,
      manifest: Self.manifest(for: contents)
    )

    let expectedSize = contents.values.reduce(0) { $0 + $1.count }
    #expect(verified.sizeBytes == Int64(expectedSize))
    #expect(verified.checksumSHA256 == Self.packChecksum(for: contents))
  }

  @Test func verifierRejectsChangedBytesWithSameFileNamesAndSizes() throws {
    let original = Self.validFixtureContents()
    let root = try Self.makeFixture(original)
    defer { Self.removeFixture(root) }

    try Self.bytes("SEGM").write(
      to: root.appendingPathComponent(Self.segmentationFixturePath, isDirectory: false),
      options: .atomic
    )

    do {
      _ = try SpeakerModelPackInstaller.verifyModelPack(
        at: root,
        manifest: Self.manifest(for: original)
      )
      Issue.record("expected checksum mismatch")
    } catch let error as ModelPackInstallError {
      guard
        case .integrityChecksumMismatch(let relativePath, let expectedSHA256, let actualSHA256) =
          error
      else {
        Issue.record("expected checksum mismatch, got \(error)")
        return
      }
      #expect(relativePath == Self.segmentationFixturePath)
      #expect(expectedSHA256 == Self.sha256(Self.bytes("segm")))
      #expect(actualSHA256 == Self.sha256(Self.bytes("SEGM")))
    } catch {
      Issue.record("expected ModelPackInstallError, got \(error)")
    }
  }

  @Test func verifierRejectsMissingExpectedFile() throws {
    let contents = [
      Self.segmentationFixturePath: Self.bytes("segm")
    ]
    let root = try Self.makeFixture(contents)
    defer { Self.removeFixture(root) }

    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(SpeakerModelPackInstaller.embeddingFile, isDirectory: true),
      withIntermediateDirectories: true
    )

    do {
      _ = try SpeakerModelPackInstaller.verifyModelPack(
        at: root,
        manifest: [
          SpeakerModelPackInstaller.ExpectedModelFile(
            relativePath: Self.segmentationFixturePath,
            sha256: Self.sha256(Self.bytes("segm"))
          ),
          SpeakerModelPackInstaller.ExpectedModelFile(
            relativePath: Self.embeddingFixturePath,
            sha256: Self.sha256(Self.bytes("spkr"))
          ),
        ]
      )
      Issue.record("expected missing file integrity error")
    } catch let error as ModelPackInstallError {
      #expect(error == .integrityExpectedFileMissing(Self.embeddingFixturePath))
    } catch {
      Issue.record("expected ModelPackInstallError, got \(error)")
    }
  }

  @Test func verifierRejectsUnexpectedRegularFile() throws {
    let contents = Self.validFixtureContents()
    let root = try Self.makeFixture(contents)
    defer { Self.removeFixture(root) }

    let unexpectedPath = "wespeaker_v2.mlmodelc/unexpected.bin"
    try Self.bytes("extra").write(
      to: root.appendingPathComponent(unexpectedPath, isDirectory: false),
      options: .atomic
    )

    do {
      _ = try SpeakerModelPackInstaller.verifyModelPack(
        at: root,
        manifest: Self.manifest(for: contents)
      )
      Issue.record("expected unexpected file integrity error")
    } catch let error as ModelPackInstallError {
      #expect(error == .integrityUnexpectedFile(unexpectedPath))
    } catch {
      Issue.record("expected ModelPackInstallError, got \(error)")
    }
  }

  private static func validFixtureContents() -> [String: Data] {
    [
      Self.segmentationFixturePath: Self.bytes("segm"),
      Self.embeddingFixturePath: Self.bytes("spkr"),
    ]
  }

  private static func manifest(for contents: [String: Data]) -> [SpeakerModelPackInstaller
    .ExpectedModelFile]
  {
    contents
      .map {
        SpeakerModelPackInstaller.ExpectedModelFile(
          relativePath: $0.key, sha256: Self.sha256($0.value))
      }
      .sorted { $0.relativePath < $1.relativePath }
  }

  private static func makeFixture(_ contents: [String: Data]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("dspeech-modelpack-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (relativePath, data) in contents {
      let fileURL = root.appendingPathComponent(relativePath, isDirectory: false)
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: fileURL, options: .atomic)
    }
    return root
  }

  private static func removeFixture(_ root: URL) {
    do {
      if FileManager.default.fileExists(atPath: root.path) {
        try FileManager.default.removeItem(at: root)
      }
    } catch {
      Issue.record("failed to remove fixture \(root.path): \(error)")
    }
  }

  private static func bytes(_ string: String) -> Data {
    Data(string.utf8)
  }

  private static func packChecksum(for contents: [String: Data]) -> String {
    var hasher = SHA256()
    for (_, data) in contents.sorted(by: { $0.key < $1.key }) {
      let digest = SHA256.hash(data: data)
      hasher.update(data: digest.withUnsafeBytes { Data($0) })
    }
    return Self.hexDigest(hasher.finalize())
  }

  private static func sha256(_ data: Data) -> String {
    Self.hexDigest(SHA256.hash(data: data))
  }

  private static func hexDigest(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}

@MainActor
struct LocalSpeakerIdentifierFactoryTests {
  static func pack(dimension: Int = 256, localModelPath: String? = nil) -> InstalledModelPack {
    InstalledModelPack(
      identifier: "fluidaudio-speaker-\(dimension)",
      version: "1.0.0",
      embeddingDimension: dimension,
      checksumSHA256: String(repeating: "a", count: 64),
      source: "https://mirror.invalid/voice-filter",
      sizeBytes: 12_345_678,
      installedAt: Date(timeIntervalSince1970: 748_137_600),
      localModelPath: localModelPath
    )
  }

  struct StubIdentifier: LocalSpeakerIdentifier {
    let vector: VoicePrintVector
    var availability: LocalSpeakerIdentifierAvailability = .available
    var embeddingDimension: Int { vector.dimension }

    func enroll(samples: [Float], sampleRate: Double) async throws -> VoicePrintVector { vector }
    func classify(
      samples: [Float],
      sampleRate: Double,
      profiles: [PilotVoiceProfile]
    ) async throws -> SpeakerMatchDecision {
      SpeakerMatcher.match(candidate: vector, profiles: profiles)
    }
  }

  struct StubBackendBuilder: LocalSpeakerBackendBuilder {
    enum Outcome: Sendable {
      case identifier(any LocalSpeakerIdentifier)
      case failsToLoad
    }

    let outcome: Outcome

    func makeIdentifier(for pack: InstalledModelPack) throws -> any LocalSpeakerIdentifier {
      switch outcome {
      case .identifier(let identifier):
        return identifier
      case .failsToLoad:
        throw LocalSpeakerIdentifierError.modelUnavailable(reason: "stub-load-failed")
      }
    }
  }

  private func isUnavailable(_ identifier: any LocalSpeakerIdentifier) -> Bool {
    if case .unavailable = identifier.availability { return true }
    return false
  }

  @Test func absentStateProducesUnavailable() {
    #expect(isUnavailable(LocalSpeakerIdentifierFactory.make(state: .absent)))
  }

  @Test func acquiringStateProducesUnavailable() {
    let identifier = LocalSpeakerIdentifierFactory.make(
      state: .acquiring(ModelPackAcquisition(phase: .downloading, fractionComplete: 0.3))
    )
    #expect(isUnavailable(identifier))
  }

  @Test func failedStateProducesUnavailable() {
    let identifier = LocalSpeakerIdentifierFactory.make(
      state: .failed(
        ModelPackFailure(kind: .network, userSafeReason: "сеть недоступна", isRetryable: true))
    )
    #expect(isUnavailable(identifier))
  }

  @Test func disabledStateProducesUnavailable() {
    #expect(isUnavailable(LocalSpeakerIdentifierFactory.make(state: .disabled(Self.pack()))))
  }

  @Test func installedWithoutBackendStaysUnavailable() {
    let identifier = LocalSpeakerIdentifierFactory.make(
      state: .installed(Self.pack()),
      backendBuilder: nil
    )
    #expect(isUnavailable(identifier))
    #expect(identifier.embeddingDimension == 256)
  }

  @Test func installedWithoutBackendKeepsPipelineNotReady() {
    let pack = Self.pack()
    let identifier = LocalSpeakerIdentifierFactory.make(
      state: .installed(pack), backendBuilder: nil)
    let pipeline = VoiceFilterPipeline(
      identifier: identifier,
      storage: VoiceFilterPipelineTests.InMemoryStorage(),
      modelPackStorage: VoiceFilterPipelineTests.InMemoryModelPackStorage(.installed(pack))
    )
    if case .ready = pipeline.capability {
      Issue.record("installed pack without a real backend must not report ready")
    }
  }

  @Test func installedWithThrowingBackendFailsOpenToUnavailable() {
    let identifier = LocalSpeakerIdentifierFactory.make(
      state: .installed(Self.pack()),
      backendBuilder: StubBackendBuilder(outcome: .failsToLoad)
    )
    #expect(isUnavailable(identifier))
  }

  @Test func installedWithUnavailableBackendStaysUnavailable() {
    let stub = StubIdentifier(
      vector: VoicePrintVector(values: Array(repeating: 0.1, count: 256), quality: 0.9),
      availability: .unavailable(reason: "backend-down")
    )
    let identifier = LocalSpeakerIdentifierFactory.make(
      state: .installed(Self.pack(dimension: 256)),
      backendBuilder: StubBackendBuilder(outcome: .identifier(stub))
    )
    #expect(isUnavailable(identifier))
  }

  @Test func installedWithDimensionMismatchStaysUnavailable() {
    let stub = StubIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.9))
    let identifier = LocalSpeakerIdentifierFactory.make(
      state: .installed(Self.pack(dimension: 256)),
      backendBuilder: StubBackendBuilder(outcome: .identifier(stub))
    )
    #expect(isUnavailable(identifier))
  }

  @Test func installedWithMatchingBackendBecomesAvailable() {
    let stub = StubIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.92))
    let identifier = LocalSpeakerIdentifierFactory.make(
      state: .installed(Self.pack(dimension: 4)),
      backendBuilder: StubBackendBuilder(outcome: .identifier(stub))
    )
    #expect(!isUnavailable(identifier))
    #expect(identifier.embeddingDimension == 4)
  }

  @Test func factoryBackedPipelineDiscardsConfidentPilotBeforeASR() async throws {
    let stub = StubIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.92))
    let pack = Self.pack(
      dimension: 4, localModelPath: "/var/mobile/Containers/Data/voice-filter/speaker-4.mlmodelc")
    let identifier = LocalSpeakerIdentifierFactory.make(
      state: .installed(pack),
      backendBuilder: StubBackendBuilder(outcome: .identifier(stub))
    )
    let store = VoiceFilterPipelineTests.InMemoryStorage()
    store.enabled = true
    store.profiles = [
      PilotVoiceProfile(
        slot: .primary,
        label: "Captain",
        voicePrint: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.9)
      )
    ]
    let pipeline = VoiceFilterPipeline(
      identifier: identifier,
      storage: store,
      modelPackStorage: VoiceFilterPipelineTests.InMemoryModelPackStorage(.installed(pack))
    )
    #expect(pipeline.capability == .ready)
    let decision = try await pipeline.classify(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)
    guard case .pilot = decision else {
      Issue.record("expected pilot decision through factory-backed pipeline, got \(decision)")
      return
    }
    #expect(pipeline.routeBeforeTranscription(speaker: decision) == .discard(reason: .pilotVoice))
  }

  @Test func factoryBackedPipelineKeepsMixedSpeechTranscribed() async throws {
    let stub = StubIdentifier(vector: VoicePrintVector(values: [0.71, 0.71, 0, 0], quality: 0.92))
    let pack = Self.pack(dimension: 4)
    let identifier = LocalSpeakerIdentifierFactory.make(
      state: .installed(pack),
      backendBuilder: StubBackendBuilder(outcome: .identifier(stub))
    )
    let store = VoiceFilterPipelineTests.InMemoryStorage()
    store.enabled = true
    store.profiles = [
      PilotVoiceProfile(
        slot: .primary, label: "Captain",
        voicePrint: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.9)),
      PilotVoiceProfile(
        slot: .secondary, label: "FO",
        voicePrint: VoicePrintVector(values: [0, 1, 0, 0], quality: 0.9)),
    ]
    let pipeline = VoiceFilterPipeline(
      identifier: identifier,
      storage: store,
      modelPackStorage: VoiceFilterPipelineTests.InMemoryModelPackStorage(.installed(pack))
    )
    let decision = try await pipeline.classify(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)
    guard case .mixed = decision else {
      Issue.record("expected mixed decision, got \(decision)")
      return
    }
    #expect(
      pipeline.routeBeforeTranscription(speaker: decision)
        == .transcribe(reason: .mixedOrLowConfidence))
  }

  @Test func manualModelPathRoundTripsThroughStorage() {
    let suiteName = "dspeech.tests.modelpack.path.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsModelPackStateStorage(defaults: defaults)
    let pack = Self.pack(
      dimension: 256,
      localModelPath: "/var/mobile/Containers/Data/voice-filter/speaker-256.mlmodelc"
    )
    store.saveState(.installed(pack))
    #expect(store.loadState() == .installed(pack))
    #expect(store.loadState().installedPack?.localModelPath == pack.localModelPath)
  }

  @Test func legacyPackJSONWithoutLocalModelPathDecodesToNil() throws {
    let legacy = """
      {"identifier":"fluidaudio-speaker-256","version":"1.0.0","embeddingDimension":256,\
      "checksumSHA256":"\(String(repeating: "a", count: 64))","source":"https://mirror.invalid/voice-filter",\
      "sizeBytes":12345678,"installedAt":0}
      """.data(using: .utf8)!
    let pack = try JSONDecoder().decode(InstalledModelPack.self, from: legacy)
    #expect(pack.localModelPath == nil)
    #expect(pack.embeddingDimension == 256)
  }
}

@MainActor
struct SpeechAudioBufferGateTests {
  final class InMemoryStorage: VoiceFilterStorage, @unchecked Sendable {
    var profiles: [PilotVoiceProfile] = []
    var callSign: CallSign?
    var config: ATCTranscriptGateConfig = .default
    var enabled: Bool = false

    func loadProfiles() -> [PilotVoiceProfile] { profiles }
    func saveProfiles(_ profiles: [PilotVoiceProfile]) { self.profiles = profiles }
    func loadCallSign() -> CallSign? { callSign }
    func saveCallSign(_ cs: CallSign?) { callSign = cs }
    func loadGateConfig() -> ATCTranscriptGateConfig { config }
    func saveGateConfig(_ c: ATCTranscriptGateConfig) { config = c }
    func loadEnabled() -> Bool { enabled }
    func saveEnabled(_ flag: Bool) { enabled = flag }
  }

  final class InMemoryModelPackStorage: ModelPackStateStorage, @unchecked Sendable {
    var state: ModelPackState
    init(_ state: ModelPackState = .absent) { self.state = state }
    func loadState() -> ModelPackState { state }
    func saveState(_ state: ModelPackState) { self.state = state }
  }

  struct ScriptedIdentifier: LocalSpeakerIdentifier {
    let decision: SpeakerMatchDecision
    var thrownError: LocalSpeakerIdentifierError?
    var availability: LocalSpeakerIdentifierAvailability = .available

    var embeddingDimension: Int { 4 }

    func enroll(samples: [Float], sampleRate: Double) async throws -> VoicePrintVector {
      if let thrownError { throw thrownError }
      return VoicePrintVector(values: [1, 0, 0, 0], quality: 0.9)
    }

    func classify(
      samples: [Float],
      sampleRate: Double,
      profiles: [PilotVoiceProfile]
    ) async throws -> SpeakerMatchDecision {
      if let thrownError { throw thrownError }
      return decision
    }
  }

  static func installedPack() -> InstalledModelPack {
    InstalledModelPack(
      identifier: "fluidaudio-speaker-256",
      version: "1.0.0",
      embeddingDimension: 256,
      checksumSHA256: String(repeating: "a", count: 64),
      source: "https://mirror.invalid/voice-filter",
      sizeBytes: 12_345_678,
      installedAt: Date(timeIntervalSince1970: 748_137_600)
    )
  }

  private static func captainProfile() -> PilotVoiceProfile {
    PilotVoiceProfile(
      slot: .primary,
      label: "Captain",
      voicePrint: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.9)
    )
  }

  private static func enabledPipeline(
    identifier: any LocalSpeakerIdentifier,
    pack: ModelPackState = .installed(installedPack())
  ) -> VoiceFilterPipeline {
    let store = InMemoryStorage()
    store.enabled = true
    store.profiles = [captainProfile()]
    return VoiceFilterPipeline(
      identifier: identifier,
      storage: store,
      modelPackStorage: InMemoryModelPackStorage(pack)
    )
  }

  @Test func confidentPilotIsDiscardedBeforeASR() async throws {
    let gate = VoiceFilterSpeechAudioBufferGate(
      pipeline: Self.enabledPipeline(
        identifier: ScriptedIdentifier(decision: .pilot(slot: .primary, score: 0.94))
      )
    )
    let route = try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)
    #expect(route == .discard(reason: .pilotVoice))
  }

  @Test func nonPilotTranscribes() async throws {
    let gate = VoiceFilterSpeechAudioBufferGate(
      pipeline: Self.enabledPipeline(
        identifier: ScriptedIdentifier(decision: .nonPilot(bestPilotScore: 0.1))
      )
    )
    let route = try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)
    #expect(route == .transcribe(reason: .nonPilotVoice))
  }

  @Test func mixedTranscribes() async throws {
    let gate = VoiceFilterSpeechAudioBufferGate(
      pipeline: Self.enabledPipeline(
        identifier: ScriptedIdentifier(decision: .mixed(bestPilotScore: 0.62))
      )
    )
    let route = try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)
    #expect(route == .transcribe(reason: .mixedOrLowConfidence))
  }

  @Test func insufficientSpeechFailsOpenToASR() async throws {
    let gate = VoiceFilterSpeechAudioBufferGate(
      pipeline: Self.enabledPipeline(
        identifier: ScriptedIdentifier(decision: .insufficientSpeech)
      )
    )
    let route = try await gate.route(samples: [0.0, 0.0, 0.0, 0.0], sampleRate: 16_000)
    #expect(route == .transcribe(reason: .insufficientSpeech))
  }

  @Test func disabledFilterTranscribes() async throws {
    let store = InMemoryStorage()
    store.enabled = false
    store.profiles = [Self.captainProfile()]
    let pipeline = VoiceFilterPipeline(
      identifier: ScriptedIdentifier(decision: .pilot(slot: .primary, score: 0.99)),
      storage: store,
      modelPackStorage: InMemoryModelPackStorage(.installed(Self.installedPack()))
    )
    let gate = VoiceFilterSpeechAudioBufferGate(pipeline: pipeline)
    let route = try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)
    #expect(route == .transcribe(reason: .filterDisabled))
  }

  @Test func privacyKillSwitchTranscribesEvenWithInstalledPackAndProfile() async throws {
    let store = InMemoryStorage()
    store.enabled = true
    store.profiles = [Self.captainProfile()]
    let pipeline = VoiceFilterPipeline(
      identifier: ScriptedIdentifier(decision: .pilot(slot: .primary, score: 0.99)),
      storage: store,
      modelPackStorage: InMemoryModelPackStorage(.installed(Self.installedPack())),
      voiceFilterActive: { false }
    )
    let gate = VoiceFilterSpeechAudioBufferGate(pipeline: pipeline)
    let route = try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)
    #expect(route == .transcribe(reason: .filterDisabled))
  }

  @Test func noProfileTranscribes() async throws {
    let store = InMemoryStorage()
    store.enabled = true
    store.profiles = []
    let pipeline = VoiceFilterPipeline(
      identifier: ScriptedIdentifier(decision: .pilot(slot: .primary, score: 0.99)),
      storage: store,
      modelPackStorage: InMemoryModelPackStorage(.installed(Self.installedPack()))
    )
    let gate = VoiceFilterSpeechAudioBufferGate(pipeline: pipeline)
    let route = try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)
    #expect(route == .transcribe(reason: .noPilotProfile))
  }

  @Test func absentPackFailsOpenToASR() async throws {
    let gate = VoiceFilterSpeechAudioBufferGate(
      pipeline: Self.enabledPipeline(
        identifier: ScriptedIdentifier(decision: .pilot(slot: .primary, score: 0.99)),
        pack: .absent
      )
    )
    let route = try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)
    #expect(route == .transcribe(reason: .classifierUnavailable))
  }

  @Test func disabledPackFailsOpenToASR() async throws {
    let gate = VoiceFilterSpeechAudioBufferGate(
      pipeline: Self.enabledPipeline(
        identifier: ScriptedIdentifier(decision: .pilot(slot: .primary, score: 0.99)),
        pack: .disabled(Self.installedPack())
      )
    )
    let route = try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)
    #expect(route == .transcribe(reason: .classifierUnavailable))
  }

  @Test func unavailableIdentifierFailsOpenToASR() async throws {
    let gate = VoiceFilterSpeechAudioBufferGate(
      pipeline: Self.enabledPipeline(identifier: UnavailableLocalSpeakerIdentifier())
    )
    let route = try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)
    #expect(route == .transcribe(reason: .classifierUnavailable))
  }

  @Test func thrownClassifierErrorFailsOpenToASR() async throws {
    let gate = VoiceFilterSpeechAudioBufferGate(
      pipeline: Self.enabledPipeline(
        identifier: ScriptedIdentifier(
          decision: .pilot(slot: .primary, score: 0.99),
          thrownError: .captureFailed(reason: "boom")
        )
      )
    )
    let route = try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)
    #expect(route == .transcribe(reason: .classifierUnavailable))
  }

  @Test func alwaysTranscribeGateNeverDiscards() async throws {
    let gate = AlwaysTranscribeSpeechAudioBufferGate()
    let route = try await gate.route(samples: [0.1, 0.2], sampleRate: 16_000)
    if case .transcribe = route {
    } else {
      Issue.record("always-transcribe gate must never discard, got \(route)")
    }
  }

  @Test func routeBeforeTranscriptionFailsOpenForInsufficientSpeech() {
    let store = InMemoryStorage()
    store.enabled = true
    store.profiles = [Self.captainProfile()]
    let pipeline = VoiceFilterPipeline(
      identifier: UnavailableLocalSpeakerIdentifier(),
      storage: store
    )
    let route = pipeline.routeBeforeTranscription(speaker: .insufficientSpeech)
    #expect(route == .transcribe(reason: .insufficientSpeech))
  }

  @Test func monoFloatSamplesExtractsMonoFloat32() {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
    buffer.frameLength = 4
    let channel = buffer.floatChannelData![0]
    let input: [Float] = [0.1, -0.2, 0.3, -0.4]
    for (i, value) in input.enumerated() { channel[i] = value }
    let samples = AppleSpeechLiveTranscriptionEngine.monoFloatSamples(from: buffer)
    #expect(samples == input)
  }

  @Test func monoFloatSamplesAveragesStereoChannels() {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
    buffer.frameLength = 2
    let left = buffer.floatChannelData![0]
    let right = buffer.floatChannelData![1]
    left[0] = 1.0
    left[1] = 0.0
    right[0] = 0.0
    right[1] = 1.0
    let samples = AppleSpeechLiveTranscriptionEngine.monoFloatSamples(from: buffer)
    #expect(samples == [0.5, 0.5])
  }

  @Test func monoFloatSamplesNilForNonFloatFormat() {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
    buffer.frameLength = 4
    #expect(AppleSpeechLiveTranscriptionEngine.monoFloatSamples(from: buffer) == nil)
  }

  @Test func monoFloatSamplesNilForEmptyBuffer() {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
    buffer.frameLength = 0
    #expect(AppleSpeechLiveTranscriptionEngine.monoFloatSamples(from: buffer) == nil)
  }
}

@MainActor
struct FluidAudioBackendBuilderTests {
  static func pack(dimension: Int = 256, localModelPath: String? = nil) -> InstalledModelPack {
    InstalledModelPack(
      identifier: "fluidaudio-speaker-\(dimension)",
      version: "1.0.0",
      embeddingDimension: dimension,
      checksumSHA256: String(repeating: "a", count: 64),
      source: "https://mirror.invalid/voice-filter",
      sizeBytes: 12_345_678,
      installedAt: Date(timeIntervalSince1970: 748_137_600),
      localModelPath: localModelPath
    )
  }

  private static let allFilesPresent: @Sendable (String) -> Bool = { _ in true }
  private static let noFilesPresent: @Sendable (String) -> Bool = { _ in false }

  private func isUnavailable(_ identifier: any LocalSpeakerIdentifier) -> Bool {
    if case .unavailable = identifier.availability { return true }
    return false
  }

  private func expectModelUnavailable(_ body: () throws -> any LocalSpeakerIdentifier) {
    do {
      _ = try body()
      Issue.record("expected makeIdentifier to throw")
    } catch let error as LocalSpeakerIdentifierError {
      if case .modelUnavailable = error {
      } else {
        Issue.record("expected modelUnavailable, got \(error)")
      }
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }

  @Test func nilLocalModelPathThrowsModelUnavailable() {
    let builder = FluidAudioBackendBuilder(fileExists: Self.allFilesPresent)
    expectModelUnavailable { try builder.makeIdentifier(for: Self.pack(localModelPath: nil)) }
  }

  @Test func emptyLocalModelPathThrowsModelUnavailable() {
    let builder = FluidAudioBackendBuilder(fileExists: Self.allFilesPresent)
    expectModelUnavailable { try builder.makeIdentifier(for: Self.pack(localModelPath: "")) }
  }

  @Test func missingModelFilesThrowsModelUnavailable() {
    let builder = FluidAudioBackendBuilder(fileExists: Self.noFilesPresent)
    expectModelUnavailable {
      try builder.makeIdentifier(for: Self.pack(localModelPath: "/var/mobile/voice-filter"))
    }
  }

  @Test func bothBundleFilesRequired() {
    let onlySegmentation: @Sendable (String) -> Bool = {
      $0.hasSuffix(FluidAudioBackendBuilder.segmentationModelFileName)
    }
    let builder = FluidAudioBackendBuilder(fileExists: onlySegmentation)
    expectModelUnavailable {
      try builder.makeIdentifier(for: Self.pack(localModelPath: "/var/mobile/voice-filter"))
    }
  }

  @Test func presentBundleFilesProduceAvailableBackendAtDimension256() throws {
    let builder = FluidAudioBackendBuilder(fileExists: Self.allFilesPresent)
    let identifier = try builder.makeIdentifier(
      for: Self.pack(dimension: 256, localModelPath: "/var/mobile/voice-filter")
    )
    #expect(!isUnavailable(identifier))
    #expect(identifier.embeddingDimension == 256)
  }

  @Test func factoryWithFluidBuilderAbsentStaysUnavailable() {
    let identifier = LocalSpeakerIdentifierFactory.make(
      state: .absent,
      backendBuilder: FluidAudioBackendBuilder(fileExists: Self.allFilesPresent)
    )
    #expect(isUnavailable(identifier))
  }

  @Test func factoryWithFluidBuilderNilPathStaysUnavailable() {
    let identifier = LocalSpeakerIdentifierFactory.make(
      state: .installed(Self.pack(localModelPath: nil)),
      backendBuilder: FluidAudioBackendBuilder(fileExists: Self.allFilesPresent)
    )
    #expect(isUnavailable(identifier))
    #expect(identifier.embeddingDimension == 256)
  }

  @Test func factoryWithFluidBuilderMissingFilesStaysUnavailable() {
    let identifier = LocalSpeakerIdentifierFactory.make(
      state: .installed(Self.pack(localModelPath: "/var/mobile/voice-filter")),
      backendBuilder: FluidAudioBackendBuilder(fileExists: Self.noFilesPresent)
    )
    #expect(isUnavailable(identifier))
  }

  @Test func factoryWithFluidBuilderDimensionMismatchStaysUnavailable() {
    let identifier = LocalSpeakerIdentifierFactory.make(
      state: .installed(Self.pack(dimension: 128, localModelPath: "/var/mobile/voice-filter")),
      backendBuilder: FluidAudioBackendBuilder(fileExists: Self.allFilesPresent)
    )
    #expect(isUnavailable(identifier))
  }

  @Test func disabledPackWithFluidBuilderStaysUnavailable() {
    let identifier = LocalSpeakerIdentifierFactory.make(
      state: .disabled(Self.pack(dimension: 256, localModelPath: "/var/mobile/voice-filter")),
      backendBuilder: FluidAudioBackendBuilder(fileExists: Self.allFilesPresent)
    )
    #expect(isUnavailable(identifier))
  }
}

struct SpeakerAudioPreprocessingTests {
  @Test func resampleIsIdentityAtTargetRate() {
    let samples: [Float] = [0.1, -0.2, 0.3, -0.4]
    #expect(SpeakerAudioPreprocessing.resample(samples, from: 16_000, to: 16_000) == samples)
  }

  @Test func resampleUpsamplesEightToSixteenK() {
    let samples: [Float] = (0..<100).map { Float($0) }
    let out = SpeakerAudioPreprocessing.resample(samples, from: 8_000, to: 16_000)
    #expect(out.count == 200)
    #expect(out.first == 0)
  }

  @Test func resampleDownsamplesFortyEightToSixteenK() {
    let samples: [Float] = Array(repeating: 0.5, count: 480)
    let out = SpeakerAudioPreprocessing.resample(samples, from: 48_000, to: 16_000)
    #expect(out.count == 160)
    #expect(out.allSatisfy { abs($0 - 0.5) < 1e-5 })
  }

  @Test func resamplePassesThroughDegenerateInput() {
    #expect(SpeakerAudioPreprocessing.resample([], from: 48_000, to: 16_000) == [])
    #expect(SpeakerAudioPreprocessing.resample([0.7], from: 48_000, to: 16_000) == [0.7])
    #expect(SpeakerAudioPreprocessing.resample([0.1, 0.2], from: 0, to: 16_000) == [0.1, 0.2])
  }

  @Test func voicedQualityIsZeroForSilence() {
    #expect(SpeakerAudioPreprocessing.voicedQuality([0, 0, 0, 0]) == 0)
    #expect(SpeakerAudioPreprocessing.voicedQuality([]) == 0)
  }

  @Test func voicedQualityRisesWithEnergyAndClampsAtOne() {
    let quiet = SpeakerAudioPreprocessing.voicedQuality([0.02, -0.02, 0.02, -0.02])
    let loud = SpeakerAudioPreprocessing.voicedQuality([0.3, -0.3, 0.3, -0.3])
    #expect(quiet < loud)
    #expect(SpeakerAudioPreprocessing.voicedQuality([1, -1, 1, -1]) == 1.0)
  }

  @Test func prepareSilenceFallsBelowQualityFloor() {
    let prepared = SpeakerAudioPreprocessing.prepare(samples: [0, 0, 0, 0], sampleRate: 16_000)
    #expect(prepared.quality < SpeakerAudioPreprocessing.minVoicedQuality)
  }

  @Test func prepareLoudSpeechMeetsQualityFloor() {
    let prepared = SpeakerAudioPreprocessing.prepare(
      samples: Array(repeating: 0.25, count: 32),
      sampleRate: 16_000
    )
    #expect(prepared.quality >= SpeakerAudioPreprocessing.minVoicedQuality)
    #expect(prepared.samples.count == 32)
  }
}
