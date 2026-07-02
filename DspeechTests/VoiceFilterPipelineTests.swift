import AVFoundation
import CryptoKit
import FluidAudio
import Foundation
import Testing

@testable import Dspeech

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
      _ = try await pipeline.enrollCrewMember(
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

  // .mixed (best cosine in [0.50, 0.72)) is reachable in production and routes through
  // indicator(for:) to its own .mixedSpeakerCandidate badge — the one indicator path not covered at
  // the pipeline level. Pins it so the mixed-band badge can't silently regress. (2026-06-15 backlog.)
  @Test func mixedSpeakerDecisionYieldsMixedSpeakerCandidateIndicator() {
    let pipeline = VoiceFilterPipeline(
      identifier: UnavailableLocalSpeakerIdentifier(),
      storage: InMemoryStorage()
    )
    pipeline.setEnabled(true)
    let dec = pipeline.decide(
      text: "traffic, two o'clock, three miles",
      speaker: .mixed(bestPilotScore: 0.62),
      timestamp: Date(timeIntervalSince1970: 0)
    )
    #expect(dec.indicator == .mixedSpeakerCandidate)
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
      #expect(reason == .filterDisabled)
    } else {
      Issue.record("disabled pipeline should display by default, got \(dec.relevance)")
    }
  }

  // An urgency broadcast must be SHOWN even with the filter OFF — the one decision the
  // disabled filter still makes (decide()'s `containsUrgencyBroadcast || enabled` short-circuit).
  // Pinned at the pipeline level (not just the gate); a confident pilot speaker proves urgency wins
  // over voice classification too. (2026-06-15 audit gap.)
  @Test func decideShowsUrgencyEvenWhenFilterDisabled() {
    let store = InMemoryStorage()
    store.callSign = CallSign(raw: "N123AB")
    let pipeline = VoiceFilterPipeline(
      identifier: UnavailableLocalSpeakerIdentifier(),
      storage: store
    )
    pipeline.setEnabled(false)
    let urgent = pipeline.decide(
      text: "MAYDAY MAYDAY MAYDAY N123AB engine failure",
      speaker: .pilot(score: 0.95),
      timestamp: Date(timeIntervalSince1970: 0)
    )
    #expect(urgent.relevance == .display(reason: .urgencyBroadcast))
    // control: a non-urgency segment in the disabled pipeline displays as filterDisabled.
    let normal = pipeline.decide(
      text: "United 247 descend",
      speaker: .pilot(score: 0.95),
      timestamp: Date(timeIntervalSince1970: 0)
    )
    #expect(normal.relevance == .display(reason: .filterDisabled))
  }

  // An uncertain-band pilot (>= match 0.72, < suppress 0.82) that the gate SHOWS (fail-open) must NOT
  // be badged .pilotSuppressed — the badge must reflect the displayed segment, else the UI audit trail
  // reads "crew suppressed" on a visible clearance. A CONFIDENT pilot still suppresses and badges
  // .pilotSuppressed. (2026-06-15 adversarial-review indicator finding.)
  @Test func uncertainPilotShownIsNotBadgedSuppressed() {
    let store = InMemoryStorage()  // no call sign -> the gate fails open and SHOWS the segment
    let pipeline = VoiceFilterPipeline(
      identifier: UnavailableLocalSpeakerIdentifier(),
      storage: store
    )
    pipeline.setEnabled(true)

    let uncertain = pipeline.decide(
      text: "descend and maintain three thousand",
      speaker: .pilot(score: 0.75),
      timestamp: Date(timeIntervalSince1970: 0)
    )
    #expect(uncertain.relevance == .display(reason: .noCallSignConfigured))
    #expect(
      uncertain.indicator != .pilotSuppressed, "a displayed segment must not be badged suppressed")
    #expect(uncertain.indicator == .probableDispatcher)

    // control: a confident pilot (>= 0.82) is suppressed and correctly badged .pilotSuppressed.
    let confident = pipeline.decide(
      text: "descend and maintain three thousand",
      speaker: .pilot(score: 0.95),
      timestamp: Date(timeIntervalSince1970: 0)
    )
    #expect(confident.relevance == .suppress(reason: .pilotReadback))
    #expect(confident.indicator == .pilotSuppressed)
  }

  // Deleting the model pack wipes enrolled voiceprints from memory AND storage — voice data
  // must not survive on disk and silently return on reinstall (the privacy/data-retention wipe).
  // Includes the idempotent second wipe. (2026-06-15 audit gap — was untested.)
  @Test func removeAllCrewMembersWipesProfilesAndStorage() {
    let store = InMemoryStorage()
    store.profiles = [
      PilotVoiceProfile(
        label: "Captain",
        voicePrint: VoicePrintVector(values: [Float](repeating: 0.1, count: 256), quality: 0.9),
        enrolledAt: Date(timeIntervalSince1970: 0))
    ]
    let pipeline = VoiceFilterPipeline(
      identifier: UnavailableLocalSpeakerIdentifier(),
      storage: store
    )
    #expect(!pipeline.profiles.isEmpty, "seeded profile did not load")

    pipeline.removeAllCrewMembers()
    #expect(pipeline.profiles.isEmpty, "wipe left profiles in memory")
    #expect(store.profiles.isEmpty, "wipe did not persist — voiceprints remain on disk")

    // a second wipe is an idempotent no-op.
    pipeline.removeAllCrewMembers()
    #expect(pipeline.profiles.isEmpty)
  }

  // The wipe must clear ON-DISK voiceprints even when in-memory profiles are already empty — a
  // corrupted/partial load can leave bytes on disk while `profiles == []` in memory, and an
  // empty-memory early-return would let that personal voice data survive the explicit removal.
  // (2026-06-15 adversarial-review privacy finding — the old guard short-circuited this.)
  @Test func removeAllCrewMembersWipesStorageEvenWhenMemoryEmpty() {
    let store = InMemoryStorage()
    let pipeline = VoiceFilterPipeline(
      identifier: UnavailableLocalSpeakerIdentifier(),
      storage: store
    )
    #expect(pipeline.profiles.isEmpty, "fresh pipeline should have no in-memory profiles")
    // Disk holds voiceprints the in-memory load did not surface (corrupted-then-recovered scenario).
    store.profiles = [
      PilotVoiceProfile(
        label: "Ghost",
        voicePrint: VoicePrintVector(values: [Float](repeating: 0.2, count: 256), quality: 0.8),
        enrolledAt: Date(timeIntervalSince1970: 0))
    ]

    pipeline.removeAllCrewMembers()

    #expect(
      store.profiles.isEmpty, "wipe must clear on-disk voiceprints even when memory was empty")
  }

  // The inconsistent cold-start state the audit flagged: pack-state says installed, but the
  // identifier (built from a stale/recovered state) is unavailable. classify must throw a typed
  // error rather than classify with the unavailable identifier. (2026-06-15 audit, two sources of
  // truth.)
  @Test func classifyThrowsWhenStateInstalledButIdentifierUnavailable() async {
    let store = InMemoryStorage()
    store.profiles = [
      PilotVoiceProfile(
        label: "Captain",
        voicePrint: VoicePrintVector(values: [Float](repeating: 0.1, count: 256), quality: 0.9),
        enrolledAt: Date(timeIntervalSince1970: 0))
    ]
    let pipeline = VoiceFilterPipeline(
      identifier: UnavailableLocalSpeakerIdentifier(reason: "stale"),
      storage: store,
      modelPackStorage: InMemoryModelPackStorage(.installed(Self.installedPack()))
    )
    pipeline.setEnabled(true)
    do {
      _ = try await pipeline.classify(samples: [0, 1, 0, 1], sampleRate: 16_000)
      Issue.record("expected throw on state/identifier disagreement")
    } catch let err as LocalSpeakerIdentifierError {
      if case .modelUnavailable = err {
      } else {
        Issue.record("expected modelUnavailable, got \(err)")
      }
    } catch {
      Issue.record("unexpected error \(error)")
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

  @Test func decideUsesUrgencyIndicatorAboveInsufficientSpeech() {
    let store = InMemoryStorage()
    store.callSign = CallSign(raw: "N123AB")
    store.enabled = true
    let pipeline = VoiceFilterPipeline(
      identifier: UnavailableLocalSpeakerIdentifier(),
      storage: store
    )
    let dec = pipeline.decide(
      text: "MAYDAY MAYDAY MAYDAY United 247",
      speaker: .insufficientSpeech,
      timestamp: Date(timeIntervalSince1970: 0)
    )
    #expect(dec.relevance == .display(reason: .urgencyBroadcast))
    #expect(dec.indicator == .urgencyBroadcast)
  }

  @Test func routeBeforeTranscriptionTranscribesPilotBeforeSTT() {
    let store = InMemoryStorage()
    store.enabled = true
    store.profiles = [
      PilotVoiceProfile(
        label: "Captain",
        voicePrint: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.9)
      )
    ]
    let pipeline = VoiceFilterPipeline(
      identifier: UnavailableLocalSpeakerIdentifier(),
      storage: store
    )
    let route = pipeline.routeBeforeTranscription(
      speaker: .pilot(score: 0.91)
    )
    #expect(route == .transcribe(reason: .pilotVoice))
  }

  @Test func routeBeforeTranscriptionKeepsMixedSegmentsVisible() {
    let store = InMemoryStorage()
    store.enabled = true
    store.profiles = [
      PilotVoiceProfile(
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
    let profile = try await pipeline.enrollCrewMember(
      label: "Captain",
      samples: [0, 1, 0, 1],
      sampleRate: 16_000,
      spokenCallSign: "N-123-AB"
    )
    #expect(profile.spokenCallSign?.normalized == "N123AB")
    #expect(store.profiles.first?.spokenCallSign?.normalized == "N123AB")
    #expect(store.callSign?.normalized == "N123AB")
  }

  @Test func enrollAppendsEachNewCrewMember() async throws {
    let store = InMemoryStorage()
    let pipeline = VoiceFilterPipeline(
      identifier: FakeIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.92)),
      storage: store,
      modelPackStorage: InMemoryModelPackStorage(.installed(Self.installedPack()))
    )
    let first = try await pipeline.enrollCrewMember(
      label: "Crew 1", samples: [0, 1], sampleRate: 16_000)
    let second = try await pipeline.enrollCrewMember(
      label: "Crew 2", samples: [1, 0], sampleRate: 16_000)
    #expect(pipeline.profiles.count == 2)
    #expect(first.id != second.id)
    #expect(store.profiles.count == 2)
  }

  // ENROLLMENT-QUALITY ASYMMETRY (intentional, 2026-06-14 incident): enrollment has NO quality gate
  // — the 0.25 minQuality floor was calibrated to reject received ATC noise for CLASSIFICATION and it
  // wrongly rejected a quietly-spoken on-device enrollment. Matching gates only the INCOMING
  // candidate's quality and never reads the enrolled profile's quality. These pin all three halves so
  // the asymmetry can't silently flip into rejecting quiet enrollments or trusting noisy candidates.
  @Test func enrollAcceptsLowQualitySampleByDesign() async throws {
    let store = InMemoryStorage()
    let pipeline = VoiceFilterPipeline(
      identifier: FakeIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.05)),
      storage: store,
      modelPackStorage: InMemoryModelPackStorage(.installed(Self.installedPack()))
    )
    let profile = try await pipeline.enrollCrewMember(
      label: "Quiet Captain", samples: [0, 1], sampleRate: 16_000)
    #expect(pipeline.profiles.count == 1)
    #expect(profile.voicePrint.quality == 0.05)
    #expect(store.profiles.first?.voicePrint.quality == 0.05)
  }

  @Test func matcherIgnoresEnrolledProfileQuality() {
    // enrolled profile is BELOW the 0.25 floor; the incoming candidate is high quality + identical.
    let profile = PilotVoiceProfile(
      label: "Captain",
      voicePrint: VoicePrintVector(values: [1, 0], quality: 0.05),
      enrolledAt: Date(timeIntervalSince1970: 0))
    let candidate = VoicePrintVector(values: [1, 0], quality: 0.9)
    let decision = SpeakerMatcher.match(candidate: candidate, profiles: [profile])
    guard case .pilot(let score) = decision else {
      Issue.record("profile quality must not gate matching; got \(decision)")
      return
    }
    #expect(score > 0.99)
  }

  @Test func matcherRejectsLowQualityIncomingCandidate() {
    // the OTHER half of the asymmetry: the incoming candidate IS gated on quality.
    let profile = PilotVoiceProfile(
      label: "Captain",
      voicePrint: VoicePrintVector(values: [1, 0], quality: 0.9),
      enrolledAt: Date(timeIntervalSince1970: 0))
    let candidate = VoicePrintVector(values: [1, 0], quality: 0.1)
    #expect(SpeakerMatcher.match(candidate: candidate, profiles: [profile]) == .insufficientSpeech)
  }

  @Test func reEnrollReplacesInPlacePreservingIdAndLabel() async throws {
    let store = InMemoryStorage()
    let pipeline = VoiceFilterPipeline(
      identifier: FakeIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.92)),
      storage: store,
      modelPackStorage: InMemoryModelPackStorage(.installed(Self.installedPack()))
    )
    let original = try await pipeline.enrollCrewMember(
      label: "Crew 1", samples: [0, 1], sampleRate: 16_000)
    let updated = try await pipeline.enrollCrewMember(
      replacing: original.id, label: "ignored-on-replace", samples: [1, 0], sampleRate: 16_000)
    #expect(pipeline.profiles.count == 1)
    #expect(updated.id == original.id)
    #expect(updated.label == "Crew 1")
  }

  @Test func removeCrewMemberRemovesById() async throws {
    let store = InMemoryStorage()
    let pipeline = VoiceFilterPipeline(
      identifier: FakeIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.92)),
      storage: store,
      modelPackStorage: InMemoryModelPackStorage(.installed(Self.installedPack()))
    )
    let first = try await pipeline.enrollCrewMember(
      label: "Crew 1", samples: [0, 1], sampleRate: 16_000)
    let second = try await pipeline.enrollCrewMember(
      label: "Crew 2", samples: [1, 0], sampleRate: 16_000)
    pipeline.removeCrewMember(id: first.id)
    #expect(pipeline.profiles.count == 1)
    #expect(pipeline.profiles.first?.id == second.id)
    #expect(store.profiles.count == 1)
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
      _ = try await pipeline.enrollCrewMember(
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

  @Test func corruptVoiceFilterStorageIssuesSurfaceInPipeline() {
    let suiteName = "dspeech.tests.voicefilter.pipeline.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data([0x00, 0x01]), forKey: UserDefaultsVoiceFilterStorage.profilesKey)
    defaults.set(Data([0x02, 0x03]), forKey: UserDefaultsVoiceFilterStorage.callSignKey)
    defaults.set("not-a-bool", forKey: UserDefaultsVoiceFilterStorage.enabledKey)
    let storage = UserDefaultsVoiceFilterStorage(defaults: defaults)

    let pipeline = VoiceFilterPipeline(
      identifier: FakeIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.92)),
      storage: storage,
      modelPackStorage: InMemoryModelPackStorage(.installed(Self.installedPack()))
    )

    #expect(
      Set(pipeline.storageIssues)
        == [.profilesCorrupted, .callSignCorrupted, .enabledFlagCorrupted])
    #expect(pipeline.profiles.isEmpty)
    #expect(pipeline.callSign == nil)
    #expect(pipeline.enabled == false)
  }

  @Test func clearingPipelineStorageIssuesResetsOnlyCorruptState() {
    let suiteName = "dspeech.tests.voicefilter.pipeline.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data([0x00, 0x01]), forKey: UserDefaultsVoiceFilterStorage.profilesKey)
    defaults.set(Data([0x02, 0x03]), forKey: UserDefaultsVoiceFilterStorage.callSignKey)
    let storage = UserDefaultsVoiceFilterStorage(defaults: defaults)

    let pipeline = VoiceFilterPipeline(
      identifier: FakeIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.92)),
      storage: storage,
      modelPackStorage: InMemoryModelPackStorage(.installed(Self.installedPack()))
    )

    pipeline.clearStorageIssues()

    #expect(pipeline.storageIssues.isEmpty)
    #expect(storage.loadSnapshot().issues.isEmpty)
    #expect(defaults.data(forKey: UserDefaultsVoiceFilterStorage.profilesKey) == nil)
    #expect(defaults.data(forKey: UserDefaultsVoiceFilterStorage.callSignKey) == nil)
  }

  @Test func installedPackClassifyDelegatesToIdentifier() async throws {
    let store = InMemoryStorage()
    store.enabled = true
    store.profiles = [
      PilotVoiceProfile(
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
    if case .pilot = decision {
      // expected: the FakeIdentifier returns a pilot decision and the pipeline delegates to it
    } else {
      Issue.record("expected delegated pilot decision, got \(decision)")
    }
  }

  @Test func voiceFilterActiveOffDisablesSpeakerClassificationButKeepsRelevanceGate() async throws {
    let store = InMemoryStorage()
    store.enabled = true
    store.callSign = CallSign(raw: "N123AB")
    store.profiles = [
      PilotVoiceProfile(
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
      speaker: .nonPilot(bestPilotScore: 0),
      timestamp: Date(timeIntervalSince1970: 0)
    )
    #expect(textDecision.relevance == .suppress(reason: .nonRelevant))
    #expect(textDecision.indicator == .otherTrafficSuppressed)

    let speaker = try await pipeline.classify(samples: [0.1, 0.2], sampleRate: 16_000)
    #expect(speaker == .nonPilot(bestPilotScore: 0))
    #expect(
      pipeline.routeBeforeTranscription(speaker: .pilot(score: 0.99))
        == .transcribe(reason: .filterDisabled)
    )
  }

  @Test func disabledFilterStillDisablesRelevanceGateWhenPrivacySpeakerToggleIsOn() {
    let store = InMemoryStorage()
    store.enabled = false
    store.callSign = CallSign(raw: "N123AB")
    let pipeline = VoiceFilterPipeline(
      identifier: FakeIdentifier(vector: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.92)),
      storage: store,
      modelPackStorage: InMemoryModelPackStorage(.installed(Self.installedPack())),
      voiceFilterActive: { true }
    )

    let textDecision = pipeline.decide(
      text: "United 247 cleared",
      speaker: .nonPilot(bestPilotScore: 0),
      timestamp: Date(timeIntervalSince1970: 0)
    )
    #expect(textDecision.relevance == .display(reason: .filterDisabled))
    #expect(textDecision.indicator == .filterOff)
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
      _ = try await pipeline.enrollCrewMember(
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
