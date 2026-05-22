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
        if case let .nonPilot(score) = decision {
            #expect(score == 0)
        } else {
            Issue.record("expected nonPilot, got \(decision)")
        }
    }

    @Test func onePilotAboveThresholdMatches() {
        let cand = Self.vector([0.95, 0.31, 0, 0])
        let profiles = [Self.profile(.primary, [1, 0.3, 0, 0])]
        let decision = SpeakerMatcher.match(candidate: cand, profiles: profiles)
        if case let .pilot(slot, score) = decision {
            #expect(slot == .primary)
            #expect(score > 0.99)
        } else {
            Issue.record("expected pilot, got \(decision)")
        }
    }

    @Test func onePilotBelowThresholdIsNonPilot() {
        let cand = Self.vector([0.2, 1.0, 0, 0])
        let profiles = [Self.profile(.primary, [1.0, 0.1, 0, 0])]
        let decision = SpeakerMatcher.match(candidate: cand, profiles: profiles)
        if case let .nonPilot(score) = decision {
            #expect(score < 0.72)
        } else {
            Issue.record("expected nonPilot, got \(decision)")
        }
    }

    @Test func twoPilotMatchesClosestSlot() {
        let cand = Self.vector([0, 1.0, 0.05, 0])
        let profiles = [
            Self.profile(.primary, [1, 0, 0, 0]),
            Self.profile(.secondary, [0, 1, 0, 0])
        ]
        let decision = SpeakerMatcher.match(candidate: cand, profiles: profiles)
        if case let .pilot(slot, _) = decision {
            #expect(slot == .secondary)
        } else {
            Issue.record("expected secondary pilot, got \(decision)")
        }
    }

    @Test func twoPilotAmbiguousFallsBackToMixedCandidate() {
        let cand = Self.vector([0.71, 0.71, 0, 0])
        let profiles = [
            Self.profile(.primary, [1, 0, 0, 0]),
            Self.profile(.secondary, [0, 1, 0, 0])
        ]
        let decision = SpeakerMatcher.match(candidate: cand, profiles: profiles)
        if case let .mixed(score) = decision {
            #expect(score > 0.6)
        } else {
            Issue.record("expected mixed ambiguous candidate, got \(decision)")
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
            enrolledAt: Date(timeIntervalSince1970: 748137600)
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
        if case let .unavailable(reason) = pipeline.capability {
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
            if case .modelUnavailable = err { } else {
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
        if case let .display(reason) = dec.relevance {
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
        if case let .display(reason) = dec.relevance {
            #expect(reason == .callSignMatch)
            #expect(dec.indicator == .dispatcherAddressedOwnCallSign)
        } else {
            Issue.record("expected callSignMatch display, got \(dec.relevance)")
        }
    }

    @Test func routeBeforeTranscriptionDiscardsPilotBeforeSTT() {
        let store = InMemoryStorage()
        store.enabled = true
        store.profiles = [PilotVoiceProfile(
            slot: .primary,
            label: "Captain",
            voicePrint: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.9)
        )]
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
        store.profiles = [PilotVoiceProfile(
            slot: .primary,
            label: "Captain",
            voicePrint: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.9)
        )]
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
            storage: store
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
}
