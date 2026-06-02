import Foundation
import Testing

@testable import Dspeech

@MainActor
struct LiveTranscriptionViewModelTests {

  @MainActor
  final class FakeEngine: LiveTranscriptionEngine {
    var status: LiveTranscriptionStatus = .idle
    var startCallCount = 0
    var stopCallCount = 0
    private var continuation: AsyncStream<LiveTranscriptionEvent>.Continuation?

    func events() -> AsyncStream<LiveTranscriptionEvent> {
      AsyncStream<LiveTranscriptionEvent> { continuation in
        self.continuation = continuation
        continuation.yield(.status(self.status))
      }
    }

    func start() async {
      startCallCount += 1
      status = .listening
      continuation?.yield(.status(.listening))
    }

    func stop() {
      stopCallCount += 1
      status = .stopped
      continuation?.yield(.status(.stopped))
    }

    func push(_ event: LiveTranscriptionEvent) {
      continuation?.yield(event)
    }
  }

  private func makeSegment(_ text: String, confidence: Double = 0.9) -> TranscriptSegment {
    TranscriptSegment(
      text: text,
      translatedText: nil,
      confidence: confidence,
      sourceLanguageCode: "en",
      source: .liveATC
    )
  }

  final class VoiceFilterMemoryStorage: VoiceFilterStorage, @unchecked Sendable {
    var profiles: [PilotVoiceProfile] = []
    var callSign: CallSign?
    var config: ATCTranscriptGateConfig = .default
    var enabled: Bool = false

    func loadProfiles() -> [PilotVoiceProfile] { profiles }
    func saveProfiles(_ profiles: [PilotVoiceProfile]) { self.profiles = profiles }
    func loadCallSign() -> CallSign? { callSign }
    func saveCallSign(_ callSign: CallSign?) { self.callSign = callSign }
    func loadGateConfig() -> ATCTranscriptGateConfig { config }
    func saveGateConfig(_ config: ATCTranscriptGateConfig) { self.config = config }
    func loadEnabled() -> Bool { enabled }
    func saveEnabled(_ enabled: Bool) { self.enabled = enabled }
  }

  @discardableResult
  private func wait(
    for predicate: @MainActor () -> Bool,
    timeout: Duration = .seconds(5)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return predicate()
  }

  @Test func initialState() {
    let engine = FakeEngine()
    let vm = LiveTranscriptionViewModel(engine: engine)
    #expect(vm.segments.isEmpty)
    #expect(vm.partialText.isEmpty)
    #expect(vm.status == .idle)
    #expect(vm.isListening == false)
  }

  @Test func startSwitchesToListening() async {
    let engine = FakeEngine()
    let vm = LiveTranscriptionViewModel(engine: engine)
    await vm.start()
    await wait(for: { vm.status == .listening })
    #expect(engine.startCallCount == 1)
    #expect(vm.isListening)
  }

  @Test func partialEventUpdatesPartialText() async {
    let engine = FakeEngine()
    let vm = LiveTranscriptionViewModel(engine: engine)
    await vm.start()
    engine.push(.partial("descend and"))
    await wait(for: { vm.partialText == "descend and" })
    #expect(vm.partialText == "descend and")
    #expect(vm.segments.isEmpty)
  }

  @Test func segmentEventAppendsAndClearsPartial() async {
    let engine = FakeEngine()
    let vm = LiveTranscriptionViewModel(engine: engine)
    await vm.start()
    engine.push(.partial("descend and"))
    await wait(for: { vm.partialText == "descend and" })
    engine.push(.segment(makeSegment("Descend and maintain three thousand.")))
    await wait(for: { vm.segments.count == 1 })
    #expect(vm.segments.first?.text == "Descend and maintain three thousand.")
    #expect(vm.segments.first?.source == .liveATC)
    #expect(vm.partialText.isEmpty)
  }

  @Test func voiceFilterSuppressesNonMatchingCallSignSegments() async {
    let engine = FakeEngine()
    let storage = VoiceFilterMemoryStorage()
    storage.enabled = true
    storage.callSign = CallSign(raw: "N123AB")
    let pipeline = VoiceFilterPipeline(
      identifier: UnavailableLocalSpeakerIdentifier(),
      storage: storage
    )
    let vm = LiveTranscriptionViewModel(engine: engine, voiceFilter: pipeline)
    await vm.start()

    engine.push(.segment(makeSegment("United 247 contact ground point niner")))
    await wait(for: { vm.segments.count == 1 && vm.visibleSegments.isEmpty })

    #expect(vm.segments.count == 1)
    #expect(vm.visibleSegments.isEmpty)
    if let stored = vm.segments.first {
      #expect(vm.indicator(for: stored) == .otherTrafficSuppressed)
    } else {
      Issue.record("expected stored suppressed segment")
    }
    #expect(vm.partialText.isEmpty)
  }

  @Test func voiceFilterDisplaysOwnCallSignSegments() async {
    let engine = FakeEngine()
    let storage = VoiceFilterMemoryStorage()
    storage.enabled = true
    storage.callSign = CallSign(raw: "N123AB")
    let pipeline = VoiceFilterPipeline(
      identifier: UnavailableLocalSpeakerIdentifier(),
      storage: storage
    )
    let vm = LiveTranscriptionViewModel(engine: engine, voiceFilter: pipeline)
    await vm.start()

    engine.push(.segment(makeSegment("N123AB descend and maintain three thousand")))
    await wait(for: { vm.visibleSegments.count == 1 })

    #expect(vm.visibleSegments.first?.text == "N123AB descend and maintain three thousand")
    if let stored = vm.visibleSegments.first {
      #expect(vm.indicator(for: stored) == .dispatcherAddressedOwnCallSign)
    } else {
      Issue.record("expected visible segment")
    }
    #expect(vm.partialText.isEmpty)
  }

  @Test func failedStatusExposesErrorMessage() async {
    let engine = FakeEngine()
    let vm = LiveTranscriptionViewModel(engine: engine)
    await vm.start()
    engine.push(.status(.failed("microphone-permission-denied")))
    #expect(
      await wait(for: {
        vm.status == .failed("microphone-permission-denied")
          && vm.lastErrorMessage == "microphone-permission-denied"
      })
    )
    #expect(vm.lastErrorMessage == "microphone-permission-denied")
    #expect(vm.isListening == false)
  }

  @Test func stopInvokesEngineAndClearsListening() async {
    let engine = FakeEngine()
    let vm = LiveTranscriptionViewModel(engine: engine)
    await vm.start()
    await wait(for: { vm.status == .listening })
    vm.stop()
    await wait(for: { vm.status == .stopped })
    #expect(engine.stopCallCount == 1)
    #expect(vm.isListening == false)
    #expect(vm.status == .stopped)
  }

  @Test func resetClearsSegmentsAndPartial() async {
    let engine = FakeEngine()
    let vm = LiveTranscriptionViewModel(engine: engine)
    await vm.start()
    engine.push(.segment(makeSegment("one")))
    engine.push(.segment(makeSegment("two")))
    engine.push(.partial("partial three"))
    await wait(for: { vm.segments.count == 2 && vm.partialText == "partial three" })
    vm.reset()
    #expect(vm.segments.isEmpty)
    #expect(vm.partialText.isEmpty)
  }

  // MARK: - Translation orchestration (F3)

  private func translatingVM(
    engine: FakeEngine,
    backend: FakeTranslationBackend,
    target: String?
  ) -> LiveTranscriptionViewModel {
    LiveTranscriptionViewModel(
      engine: engine,
      translator: backend,
      translationTarget: { target.map { Locale.Language(identifier: $0) } }
    )
  }

  @Test func translatesFinalizedSegmentWhenEnabled() async {
    let engine = FakeEngine()
    let backend = FakeTranslationBackend()
    backend.translationResult = "Снижайтесь до трёх тысяч"
    let vm = translatingVM(engine: engine, backend: backend, target: "ru")
    await vm.start()
    let seg = makeSegment("Descend and maintain three thousand")
    engine.push(.segment(seg))
    #expect(await wait(for: { vm.translations[seg.id] == "Снижайтесь до трёх тысяч" }))
    #expect(backend.translateCallCount == 1)
  }

  @Test func skipsTranslationWhenTargetEqualsSource() async {
    let engine = FakeEngine()
    let backend = FakeTranslationBackend()
    let vm = translatingVM(engine: engine, backend: backend, target: "en")
    await vm.start()
    let seg = makeSegment("Descend and maintain three thousand")
    engine.push(.segment(seg))
    await wait(for: { vm.segments.count == 1 })
    _ = await wait(for: { backend.translateCallCount > 0 }, timeout: .milliseconds(300))
    #expect(backend.translateCallCount == 0)
    #expect(vm.translations[seg.id] == nil)
  }

  @Test func doesNotTranslateWhenDisabled() async {
    let engine = FakeEngine()
    let backend = FakeTranslationBackend()
    let vm = translatingVM(engine: engine, backend: backend, target: nil)
    await vm.start()
    let seg = makeSegment("Descend")
    engine.push(.segment(seg))
    await wait(for: { vm.segments.count == 1 })
    _ = await wait(for: { backend.translateCallCount > 0 }, timeout: .milliseconds(300))
    #expect(backend.translateCallCount == 0)
  }

  @Test func missingLanguagePackMarksUnavailable() async {
    let engine = FakeEngine()
    let backend = FakeTranslationBackend()
    backend.translateError = .languagePackNotInstalled(
      source: Locale.Language(identifier: "en"),
      target: Locale.Language(identifier: "ru"))
    let vm = translatingVM(engine: engine, backend: backend, target: "ru")
    await vm.start()
    let seg = makeSegment("Descend")
    engine.push(.segment(seg))
    #expect(await wait(for: { vm.translationUnavailable }))
    #expect(vm.translations[seg.id] == nil)
  }

  @Test func resetClearsTranslations() async {
    let engine = FakeEngine()
    let backend = FakeTranslationBackend()
    backend.translationResult = "перевод"
    let vm = translatingVM(engine: engine, backend: backend, target: "ru")
    await vm.start()
    let seg = makeSegment("Descend")
    engine.push(.segment(seg))
    await wait(for: { vm.translations[seg.id] == "перевод" })
    vm.reset()
    #expect(vm.translations.isEmpty)
    #expect(vm.translationUnavailable == false)
  }

  @Test func retranslateAllRetranslatesExistingSegments() async {
    let engine = FakeEngine()
    let backend = FakeTranslationBackend()
    backend.translationResult = "перевод"
    let vm = translatingVM(engine: engine, backend: backend, target: "ru")
    await vm.start()
    let seg = makeSegment("Descend")
    engine.push(.segment(seg))
    await wait(for: { vm.translations[seg.id] == "перевод" })
    let firstCount = backend.translateCallCount
    vm.retranslateAll()
    #expect(await wait(for: { backend.translateCallCount > firstCount }))
    #expect(vm.translations[seg.id] == "перевод")
  }
}
