@preconcurrency import Foundation
import Testing

@testable import Dspeech

private final class NetworkAttemptStore: @unchecked Sendable {
  struct Attempt: Sendable {
    let sequence: Int
    let scopeID: UUID?
    let url: URL
  }

  static let shared = NetworkAttemptStore()
  private let lock = NSLock()
  private var nextSequence = 0
  private var attempts: [Attempt] = []

  func mark() -> Int {
    lock.withLock {
      nextSequence
    }
  }

  func record(_ url: URL, scopeID: UUID?) {
    lock.withLock {
      attempts.append(Attempt(sequence: nextSequence, scopeID: scopeID, url: url))
      nextSequence += 1
    }
  }

  func snapshot(scopeID: UUID, since startSequence: Int, includeUnscoped: Bool) -> [URL] {
    lock.withLock {
      attempts
        .filter { attempt in
          attempt.sequence >= startSequence
            && (attempt.scopeID == scopeID || (includeUnscoped && attempt.scopeID == nil))
        }
        .map(\.url)
    }
  }
}

private let networkDenyScopeIDKey = "DspeechTests.NetworkDenyScopeID"

private final class DenyAllNetworkURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url != nil
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    if let url = request.url {
      let scopeID = URLProtocol.property(forKey: networkDenyScopeIDKey, in: request) as? UUID
      NetworkAttemptStore.shared.record(url, scopeID: scopeID)
    }
    client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
  }

  override func stopLoading() {}
}

private struct NetworkDenyScope {
  private let id = UUID()
  private let startSequence: Int
  private let capturesUnscopedAttempts: Bool
  private let registeredGlobalProtocol: Bool

  init(registerGlobalProtocol: Bool = true) {
    startSequence = NetworkAttemptStore.shared.mark()
    capturesUnscopedAttempts = registerGlobalProtocol
    registeredGlobalProtocol = registerGlobalProtocol
    if registerGlobalProtocol {
      URLProtocol.registerClass(DenyAllNetworkURLProtocol.self)
    }
  }

  func makeGuardedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DenyAllNetworkURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  func makeGuardedRequest(url: URL) -> URLRequest {
    let request = NSMutableURLRequest(url: url)
    URLProtocol.setProperty(id, forKey: networkDenyScopeIDKey, in: request)
    return request as URLRequest
  }

  func attempts() -> [URL] {
    NetworkAttemptStore.shared.snapshot(
      scopeID: id,
      since: startSequence,
      includeUnscoped: capturesUnscopedAttempts
    )
  }

  func close() {
    if registeredGlobalProtocol {
      URLProtocol.unregisterClass(DenyAllNetworkURLProtocol.self)
    }
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
      throw LocalSpeakerIdentifierError.captureFailed(
        reason: "Replay test only covers local-only privacy mode.")
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
      ),
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
    #expect(
      emitted == [
        "Tower N123AB cleared for takeoff",
        "N123AB continue climb",
      ])
    #expect(scope.attempts().isEmpty)
  }

  @Test func urlSessionGuardFailsRequestsWithoutRealNetwork() async {
    let scope = NetworkDenyScope(registerGlobalProtocol: false)
    defer { scope.close() }
    let session = scope.makeGuardedSession()
    let request = scope.makeGuardedRequest(url: URL(string: "https://egress.invalid/probe")!)

    do {
      _ = try await session.data(for: request)
      Issue.record("The guarded URLSession should fail before any real network access.")
    } catch {
      #expect(scope.attempts() == [URL(string: "https://egress.invalid/probe")!])
    }
  }
}
