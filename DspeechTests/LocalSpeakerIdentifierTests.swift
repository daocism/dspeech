import AVFoundation
import CryptoKit
import FluidAudio
import Foundation
import Testing

@testable import Dspeech

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
    #expect(
      pipeline.routeBeforeTranscription(speaker: decision)
        == .transcribe(reason: .pilotVoice))
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
        label: "Captain",
        voicePrint: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.9)),
      PilotVoiceProfile(
        label: "FO",
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

  @Test func confidentPilotTranscribesBeforeASR() async throws {
    let gate = VoiceFilterSpeechAudioBufferGate(
      pipeline: Self.enabledPipeline(
        identifier: ScriptedIdentifier(decision: .pilot(score: 1.0))
      )
    )
    let route = (try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)).routing
    #expect(route == .transcribe(reason: .pilotVoice))
  }

  @Test func pilotClassifiedBufferStillReachesAppend() async {
    let gate = VoiceFilterSpeechAudioBufferGate(
      pipeline: Self.enabledPipeline(
        identifier: ScriptedIdentifier(decision: .pilot(score: 1.0))
      )
    )
    let (appended, appendContinuation) = AsyncStream<Int>.makeStream()
    let router = SerialBufferRouter<Int>(
      classify: { samples, sampleRate in
        (try await gate.route(samples: samples, sampleRate: sampleRate)).routing
      },
      append: { appendContinuation.yield($0) }
    )

    router.submit(1, samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)

    var iterator = appended.makeAsyncIterator()
    #expect(await iterator.next() == 1)
    appendContinuation.finish()
  }

  @Test func nonPilotTranscribes() async throws {
    let gate = VoiceFilterSpeechAudioBufferGate(
      pipeline: Self.enabledPipeline(
        identifier: ScriptedIdentifier(decision: .nonPilot(bestPilotScore: 0.1))
      )
    )
    let route = (try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)).routing
    #expect(route == .transcribe(reason: .nonPilotVoice))
  }

  @Test func mixedTranscribes() async throws {
    let gate = VoiceFilterSpeechAudioBufferGate(
      pipeline: Self.enabledPipeline(
        identifier: ScriptedIdentifier(decision: .mixed(bestPilotScore: 0.62))
      )
    )
    let route = (try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)).routing
    #expect(route == .transcribe(reason: .mixedOrLowConfidence))
  }

  @Test func insufficientSpeechFailsOpenToASR() async throws {
    let gate = VoiceFilterSpeechAudioBufferGate(
      pipeline: Self.enabledPipeline(
        identifier: ScriptedIdentifier(decision: .insufficientSpeech)
      )
    )
    let route = (try await gate.route(samples: [0.0, 0.0, 0.0, 0.0], sampleRate: 16_000)).routing
    #expect(route == .transcribe(reason: .insufficientSpeech))
  }

  @Test func disabledFilterTranscribes() async throws {
    let store = InMemoryStorage()
    store.enabled = false
    store.profiles = [Self.captainProfile()]
    let pipeline = VoiceFilterPipeline(
      identifier: ScriptedIdentifier(decision: .pilot(score: 0.99)),
      storage: store,
      modelPackStorage: InMemoryModelPackStorage(.installed(Self.installedPack()))
    )
    let gate = VoiceFilterSpeechAudioBufferGate(pipeline: pipeline)
    let route = (try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)).routing
    #expect(route == .transcribe(reason: .filterDisabled))
  }

  @Test func privacyKillSwitchTranscribesEvenWithInstalledPackAndProfile() async throws {
    let store = InMemoryStorage()
    store.enabled = true
    store.profiles = [Self.captainProfile()]
    let pipeline = VoiceFilterPipeline(
      identifier: ScriptedIdentifier(decision: .pilot(score: 0.99)),
      storage: store,
      modelPackStorage: InMemoryModelPackStorage(.installed(Self.installedPack())),
      voiceFilterActive: { false }
    )
    let gate = VoiceFilterSpeechAudioBufferGate(pipeline: pipeline)
    let route = (try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)).routing
    #expect(route == .transcribe(reason: .filterDisabled))
  }

  @Test func noProfileTranscribes() async throws {
    let store = InMemoryStorage()
    store.enabled = true
    store.profiles = []
    let pipeline = VoiceFilterPipeline(
      identifier: ScriptedIdentifier(decision: .pilot(score: 0.99)),
      storage: store,
      modelPackStorage: InMemoryModelPackStorage(.installed(Self.installedPack()))
    )
    let gate = VoiceFilterSpeechAudioBufferGate(pipeline: pipeline)
    let route = (try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)).routing
    #expect(route == .transcribe(reason: .noPilotProfile))
  }

  @Test func absentPackFailsOpenToASR() async throws {
    let gate = VoiceFilterSpeechAudioBufferGate(
      pipeline: Self.enabledPipeline(
        identifier: ScriptedIdentifier(decision: .pilot(score: 0.99)),
        pack: .absent
      )
    )
    let route = (try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)).routing
    #expect(route == .transcribe(reason: .classifierUnavailable))
  }

  @Test func disabledPackFailsOpenToASR() async throws {
    let gate = VoiceFilterSpeechAudioBufferGate(
      pipeline: Self.enabledPipeline(
        identifier: ScriptedIdentifier(decision: .pilot(score: 0.99)),
        pack: .disabled(Self.installedPack())
      )
    )
    let route = (try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)).routing
    #expect(route == .transcribe(reason: .classifierUnavailable))
  }

  @Test func unavailableIdentifierFailsOpenToASR() async throws {
    let gate = VoiceFilterSpeechAudioBufferGate(
      pipeline: Self.enabledPipeline(identifier: UnavailableLocalSpeakerIdentifier())
    )
    let route = (try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)).routing
    #expect(route == .transcribe(reason: .classifierUnavailable))
  }

  @Test func thrownClassifierErrorFailsOpenToASR() async throws {
    let gate = VoiceFilterSpeechAudioBufferGate(
      pipeline: Self.enabledPipeline(
        identifier: ScriptedIdentifier(
          decision: .pilot(score: 0.99),
          thrownError: .captureFailed(reason: "boom")
        )
      )
    )
    let route = (try await gate.route(samples: [0.1, 0.2, 0.1, 0.2], sampleRate: 16_000)).routing
    #expect(route == .transcribe(reason: .classifierUnavailable))
  }

  @Test func alwaysTranscribeGateNeverDiscards() async throws {
    let gate = AlwaysTranscribeSpeechAudioBufferGate()
    let route = (try await gate.route(samples: [0.1, 0.2], sampleRate: 16_000)).routing
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
