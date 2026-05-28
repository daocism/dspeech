@preconcurrency import Foundation
import Testing
@testable import Dspeech

private final class NetworkAttemptStore: @unchecked Sendable {
    static let shared = NetworkAttemptStore()

    private let lock = NSLock()
    private var attemptedURLs: [URL] = []

    func reset() {
        lock.withLock {
            attemptedURLs.removeAll()
        }
    }

    func record(_ url: URL) {
        lock.withLock {
            attemptedURLs.append(url)
        }
    }

    func snapshot() -> [URL] {
        lock.withLock { attemptedURLs }
    }
}

private final class DenyAllNetworkURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let url = request.url {
            NetworkAttemptStore.shared.record(url)
        }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

private struct NetworkDenyScope {
    init() {
        NetworkAttemptStore.shared.reset()
        URLProtocol.registerClass(DenyAllNetworkURLProtocol.self)
    }

    func makeGuardedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DenyAllNetworkURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func attempts() -> [URL] {
        NetworkAttemptStore.shared.snapshot()
    }

    func close() {
        URLProtocol.unregisterClass(DenyAllNetworkURLProtocol.self)
    }
}

private final class ReplayVoiceFilterStorage: VoiceFilterStorage, @unchecked Sendable {
    var profiles: [PilotVoiceProfile]
    var callSign: CallSign?
    var config: ATCTranscriptGateConfig
    var enabled: Bool

    init(
        profiles: [PilotVoiceProfile],
        callSign: CallSign?,
        config: ATCTranscriptGateConfig = .default,
        enabled: Bool
    ) {
        self.profiles = profiles
        self.callSign = callSign
        self.config = config
        self.enabled = enabled
    }

    func loadProfiles() -> [PilotVoiceProfile] { profiles }
    func saveProfiles(_ profiles: [PilotVoiceProfile]) { self.profiles = profiles }
    func loadCallSign() -> CallSign? { callSign }
    func saveCallSign(_ callSign: CallSign?) { self.callSign = callSign }
    func loadGateConfig() -> ATCTranscriptGateConfig { config }
    func saveGateConfig(_ config: ATCTranscriptGateConfig) { self.config = config }
    func loadEnabled() -> Bool { enabled }
    func saveEnabled(_ enabled: Bool) { self.enabled = enabled }
}

private final class ReplayModelPackStorage: ModelPackStateStorage, @unchecked Sendable {
    var state: ModelPackState

    init(_ state: ModelPackState) {
        self.state = state
    }

    func loadState() -> ModelPackState { state }
    func saveState(_ state: ModelPackState) { self.state = state }
}

private struct AudioDerivedIdentifier: LocalSpeakerIdentifier {
    let availability: LocalSpeakerIdentifierAvailability = .available
    let embeddingDimension = 4

    func enroll(samples: [Float], sampleRate: Double) async throws -> VoicePrintVector {
        _ = samples
        _ = sampleRate
        return VoicePrintVector(values: [1, 0, 0, 0], quality: 0.95)
    }

    func classify(
        samples: [Float],
        sampleRate: Double,
        profiles: [PilotVoiceProfile]
    ) async throws -> SpeakerMatchDecision {
        _ = sampleRate
        guard !samples.isEmpty else { return .insufficientSpeech }
        let averageMagnitude = samples.reduce(Float(0)) { $0 + abs($1) } / Float(samples.count)
        let vector: VoicePrintVector
        if averageMagnitude >= 0.80 {
            vector = VoicePrintVector(values: [1, 0, 0, 0], quality: 0.95)
        } else if averageMagnitude >= 0.55 {
            vector = VoicePrintVector(values: [0.7, 0.7, 0, 0], quality: 0.95)
        } else {
            vector = VoicePrintVector(values: [0, 1, 0, 0], quality: 0.95)
        }
        return SpeakerMatcher.match(candidate: vector, profiles: profiles)
    }
}

private struct CapturedReplayFrame: Sendable {
    let samples: [Float]
    let transcript: String
}

private struct DeterministicReplayTranscriber: Sendable {
    func transcribe(_ frame: CapturedReplayFrame, privacyMode: PrivacyMode) throws -> String {
        guard privacyMode == .localOnly else {
            throw LocalSpeakerIdentifierError.captureFailed(reason: "Replay test only covers local-only privacy mode.")
        }
        return frame.transcript
    }
}

@MainActor
struct ReplayKitNetworkDenyTests {
    private static func installedPack() -> InstalledModelPack {
        InstalledModelPack(
            identifier: "synthetic-replay-speaker",
            version: "1.0.0",
            embeddingDimension: 4,
            checksumSHA256: String(repeating: "b", count: 64),
            source: "local-fixture",
            sizeBytes: 4096,
            installedAt: Date(timeIntervalSince1970: 748_137_600),
            localModelPath: "/private/var/mobile/Containers/Data/Application/Dspeech/voice-filter"
        )
    }

    private static func makePipeline() -> VoiceFilterPipeline {
        let profile = PilotVoiceProfile(
            slot: .primary,
            label: "Captain",
            voicePrint: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.95),
            enrolledAt: Date(timeIntervalSince1970: 748_137_600),
            spokenCallSign: CallSign(raw: "N123AB")
        )
        let storage = ReplayVoiceFilterStorage(
            profiles: [profile],
            callSign: CallSign(raw: "N123AB"),
            enabled: true
        )
        return VoiceFilterPipeline(
            identifier: AudioDerivedIdentifier(),
            storage: storage,
            modelPackStorage: ReplayModelPackStorage(.installed(installedPack()))
        )
    }

    @Test func localOnlyCaptureTranscribeFilterPipelineMakesZeroNetworkAttempts() async throws {
        let privacyMode = PrivacyMode.localOnly
        let scope = NetworkDenyScope()
        defer { scope.close() }

        let pipeline = Self.makePipeline()
        let transcriber = DeterministicReplayTranscriber()
        let frames = [
            CapturedReplayFrame(
                samples: Array(repeating: 0.20, count: 64),
                transcript: "Tower N123AB cleared for takeoff"
            ),
            CapturedReplayFrame(
                samples: Array(repeating: 0.92, count: 64),
                transcript: "N123AB rolling"
            ),
            CapturedReplayFrame(
                samples: Array(repeating: 0.63, count: 64),
                transcript: "N123AB continue climb"
            )
        ]

        var emitted: [String] = []
        var discarded = 0
        for frame in frames {
            let speaker = try await pipeline.classify(samples: frame.samples, sampleRate: 16_000)
            switch pipeline.routeBeforeTranscription(speaker: speaker) {
            case .discard(reason: .pilotVoice):
                discarded += 1
            case .discard:
                Issue.record("Only confident pilot audio may be discarded before ASR.")
            case .transcribe:
                let transcript = try transcriber.transcribe(frame, privacyMode: privacyMode)
                let decision = pipeline.decide(text: transcript, speaker: speaker)
                if case .display = decision.relevance {
                    emitted.append(decision.segmentText)
                }
            }
        }

        #expect(privacyMode.sendsAudioOffDevice == false)
        #expect(discarded == 1)
        #expect(emitted == [
            "Tower N123AB cleared for takeoff",
            "N123AB continue climb"
        ])
        #expect(scope.attempts().isEmpty)
    }

    @Test func urlSessionGuardFailsRequestsWithoutRealNetwork() async {
        let scope = NetworkDenyScope()
        defer { scope.close() }
        let session = scope.makeGuardedSession()

        do {
            _ = try await session.data(from: URL(string: "https://egress.invalid/probe")!)
            Issue.record("The guarded URLSession should fail before any real network access.")
        } catch {
            #expect(scope.attempts() == [URL(string: "https://egress.invalid/probe")!])
        }
    }
}
