import Foundation
import Testing

@testable import Dspeech

// why: this suite drives a MainActor view model with unstructured observation and translation
// tasks. Swift Testing may otherwise overlap cases on the cold hosted runner, starving the
// MainActor long enough that first attempts pass only after retry. Keep it serialized so a
// retry is never required to get deterministic event delivery.
@Suite(.serialized)
@MainActor
struct LiveTranscriptionViewModelTests {

  @MainActor
  final class FakeEngine: LiveTranscriptionEngine {
    var status: LiveTranscriptionStatus = .idle
    var startCallCount = 0
    var stopCallCount = 0
    var startSuspends = false
    private var continuation: AsyncStream<LiveTranscriptionEvent>.Continuation?
    private var pendingStartContinuation: CheckedContinuation<Void, Never>?

    init(startSuspends: Bool = false) {
      self.startSuspends = startSuspends
    }

    func events() -> AsyncStream<LiveTranscriptionEvent> {
      AsyncStream<LiveTranscriptionEvent> { continuation in
        self.continuation = continuation
        continuation.yield(.status(self.status))
      }
    }

    func start() async {
      startCallCount += 1
      status = .requestingPermission
      continuation?.yield(.status(.requestingPermission))
      if startSuspends {
        await withCheckedContinuation { continuation in
          pendingStartContinuation = continuation
        }
        guard status != .stopped else { return }
      }
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

    func completeStart() {
      let continuation = pendingStartContinuation
      pendingStartContinuation = nil
      continuation?.resume()
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

  // why: test cases are serialized on MainActor; mutable state never crosses concurrent callers.
  final class FirstSessionMemoryStorage: FirstSessionStateStorage, @unchecked Sendable {
    var stored: Bool

    init(stored: Bool = false) {
      self.stored = stored
    }

    func loadHasEverStarted() -> Bool { stored }
    func saveHasEverStarted(_ hasEverStarted: Bool) { stored = hasEverStarted }
  }

  struct StoreFailure: Error, Equatable {}

  final class FakeTranscriptStore: TranscriptStoring {
    var beginLocaleIdentifiers: [String] = []
    var appendedSegments: [(sessionID: UUID, segment: TranscriptSegment)] = []
    var endedSessionIDs: [UUID] = []
    var beginError: StoreFailure?
    var appendError: StoreFailure?
    var endError: StoreFailure?
    private var nextSessionID = UUID()

    func beginSession(localeIdentifier: String) throws -> TranscriptSessionSummary {
      if let beginError { throw beginError }
      beginLocaleIdentifiers.append(localeIdentifier)
      return TranscriptSessionSummary(
        id: nextSessionID,
        startedAt: Date(timeIntervalSince1970: 1_000),
        endedAt: nil,
        segmentCount: 0,
        localeIdentifier: localeIdentifier
      )
    }

    func append(_ segment: TranscriptSegment, to sessionID: UUID) throws {
      if let appendError { throw appendError }
      appendedSegments.append((sessionID, segment))
    }

    func endSession(_ sessionID: UUID) throws {
      if let endError { throw endError }
      endedSessionIDs.append(sessionID)
    }

    func sessions() throws -> [TranscriptSessionSummary] { [] }
    func segments(in sessionID: UUID) throws -> [TranscriptSegment] { [] }
    func deleteSession(_ sessionID: UUID) throws {}
    func exportText(for sessionID: UUID) throws -> String { "" }
  }

  @discardableResult
  private func wait(
    for predicate: @MainActor () -> Bool,
    timeout: Duration = .seconds(30)
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

  @Test func stopCommitsInProgressPartialSoTranscriptPersists() async {
    let engine = FakeEngine()
    let vm = LiveTranscriptionViewModel(engine: engine)
    await vm.start()
    engine.push(.partial("descend and maintain three thousand"))
    await wait(for: { vm.partialText == "descend and maintain three thousand" })
    vm.stop()
    await wait(for: { vm.status == .stopped })
    #expect(vm.partialText.isEmpty)
    // the partial is committed as a segment instead of vanishing on Stop
    #expect(vm.segments.count == 1)
    #expect(vm.segments.first?.text == "descend and maintain three thousand")
    #expect(vm.segments.first?.isStopCommittedPlaceholder == true)
    #expect(vm.segments.first?.requiresVerification == true)
    #expect(vm.visibleSegments.count == 1)
  }

  @Test func lateFinalAfterStopReplacesPlaceholderInsteadOfDuplicating() async {
    let engine = FakeEngine()
    let vm = LiveTranscriptionViewModel(engine: engine)
    await vm.start()
    engine.push(.partial("November one two three alpha bravo"))
    await wait(for: { vm.partialText == "November one two three alpha bravo" })
    // Stop commits the in-flight partial as a confidence-0 placeholder…
    vm.stop()
    await wait(for: { vm.segments.count == 1 })
    #expect(vm.segments.first?.confidence == 0)
    #expect(vm.segments.first?.isStopCommittedPlaceholder == true)
    // …then the recognizer's real final for the SAME utterance arrives a beat later.
    engine.push(.segment(makeSegment("November one two three alpha bravo", confidence: 0.91)))
    await wait(for: { (vm.segments.first?.confidence ?? 0) > 0 })
    #expect(vm.segments.count == 1)
    #expect(vm.segments.first?.confidence == 0.91)
    #expect(vm.segments.first?.isStopCommittedPlaceholder == false)
  }

  @Test func lateZeroConfidenceFinalAfterStopReplacesPlaceholderByFlag() async {
    let engine = FakeEngine()
    let vm = LiveTranscriptionViewModel(engine: engine)
    await vm.start()
    engine.push(.partial("November one two three alpha bravo"))
    await wait(for: { vm.partialText == "November one two three alpha bravo" })
    vm.stop()
    await wait(for: { vm.segments.count == 1 })
    #expect(vm.segments.first?.isStopCommittedPlaceholder == true)

    engine.push(.segment(makeSegment("November one two three alpha bravo", confidence: 0)))
    await wait(for: { vm.segments.first?.isStopCommittedPlaceholder == false })

    #expect(vm.segments.count == 1)
    #expect(vm.segments.first?.confidence == 0)
  }

  @Test func realZeroConfidenceFinalIsNotTreatedAsStopPlaceholder() async {
    let engine = FakeEngine()
    let vm = LiveTranscriptionViewModel(engine: engine)
    await vm.start()
    engine.push(.segment(makeSegment("November one two three alpha bravo", confidence: 0)))
    await wait(for: { vm.segments.count == 1 })

    engine.push(.segment(makeSegment("November one two three alpha bravo", confidence: 0.91)))
    await wait(for: { vm.segments.count == 2 })

    #expect(vm.segments.count == 2)
    #expect(vm.segments.first?.isStopCommittedPlaceholder == false)
  }

  @Test func distinctFinalAfterStopIsNotMergedIntoPlaceholder() async {
    let engine = FakeEngine()
    let vm = LiveTranscriptionViewModel(engine: engine)
    await vm.start()
    engine.push(.partial("hold short runway two seven"))
    await wait(for: { vm.partialText == "hold short runway two seven" })
    vm.stop()
    await wait(for: { vm.segments.count == 1 })
    // a DIFFERENT final must not overwrite the placeholder
    engine.push(.segment(makeSegment("cleared for takeoff runway two seven", confidence: 0.9)))
    await wait(for: { vm.segments.count == 2 })
    #expect(vm.segments.count == 2)
  }

  @Test func stopWithNoPartialCommitsNothing() async {
    let engine = FakeEngine()
    let vm = LiveTranscriptionViewModel(engine: engine)
    await vm.start()
    vm.stop()
    await wait(for: { vm.status == .stopped })
    #expect(vm.segments.isEmpty)
  }

  @Test func hasEverStartedFlipsOnFirstStart() async {
    let engine = FakeEngine()
    let firstSessionStorage = FirstSessionMemoryStorage()
    let vm = LiveTranscriptionViewModel(engine: engine, firstSessionStorage: firstSessionStorage)
    #expect(vm.hasEverStarted == false)
    await vm.start()
    #expect(vm.hasEverStarted)
    #expect(firstSessionStorage.stored)
  }

  @Test func persistedHasEverStartedIsLoadedOnInit() {
    let engine = FakeEngine()
    let vm = LiveTranscriptionViewModel(
      engine: engine,
      firstSessionStorage: FirstSessionMemoryStorage(stored: true)
    )

    #expect(vm.hasEverStarted)
  }

  @Test func persistenceBeginsAppendsAndEndsLiveSession() async throws {
    let engine = FakeEngine()
    let store = FakeTranscriptStore()
    let vm = LiveTranscriptionViewModel(
      engine: engine,
      transcriptStore: store,
      recognitionLocaleIdentifier: { "fr-FR" }
    )
    await vm.start()
    #expect(await wait(for: { store.beginLocaleIdentifiers == ["fr-FR"] }))

    let segment = makeSegment("Descend and maintain three thousand.")
    engine.push(.segment(segment))
    #expect(await wait(for: { store.appendedSegments.count == 1 }))

    vm.stop()
    #expect(await wait(for: { store.endedSessionIDs.count == 1 }))

    let appended = try #require(store.appendedSegments.first)
    #expect(appended.segment == segment)
    #expect(appended.sessionID == store.endedSessionIDs.first)
  }

  @Test func persistenceSkipsDemoSegments() async {
    let engine = FakeEngine()
    let store = FakeTranscriptStore()
    let vm = LiveTranscriptionViewModel(engine: engine, transcriptStore: store)
    await vm.start()
    let demo = TranscriptSegment(
      text: "Demo traffic",
      confidence: 0.9,
      sourceLanguageCode: "en",
      source: .demo
    )

    engine.push(.segment(demo))
    #expect(await wait(for: { vm.segments.count == 1 }))

    #expect(store.appendedSegments.isEmpty)
  }

  @Test func persistenceAppendsStopCommittedPlaceholders() async throws {
    let engine = FakeEngine()
    let store = FakeTranscriptStore()
    let vm = LiveTranscriptionViewModel(engine: engine, transcriptStore: store)
    await vm.start()
    engine.push(.partial("hold short runway two seven"))
    await wait(for: { vm.partialText == "hold short runway two seven" })

    vm.stop()
    await wait(for: { vm.segments.count == 1 && vm.status == .stopped })

    let persisted = try #require(store.appendedSegments.first?.segment)
    #expect(store.appendedSegments.count == 1)
    #expect(persisted.text == "hold short runway two seven")
    #expect(persisted.isStopCommittedPlaceholder)
  }

  @Test func persistenceAppendsLateFinalAfterStopPlaceholderReplacement() async throws {
    let engine = FakeEngine()
    let store = FakeTranscriptStore()
    let vm = LiveTranscriptionViewModel(engine: engine, transcriptStore: store)
    await vm.start()
    engine.push(.partial("November one two three alpha bravo"))
    await wait(for: { vm.partialText == "November one two three alpha bravo" })

    vm.stop()
    await wait(for: { vm.segments.count == 1 && vm.status == .stopped })
    engine.push(.segment(makeSegment("November one two three alpha bravo", confidence: 0.91)))
    await wait(for: { store.appendedSegments.count == 2 })

    #expect(vm.segments.count == 1)
    #expect(vm.segments.first?.isStopCommittedPlaceholder == false)
    #expect(store.appendedSegments.map(\.segment.isStopCommittedPlaceholder) == [true, false])
    #expect(
      store.appendedSegments.map(\.segment.text) == [
        "November one two three alpha bravo", "November one two three alpha bravo",
      ])
  }

  @Test func persistenceAppendFailureWarnsWithoutDroppingSegment() async {
    let engine = FakeEngine()
    let store = FakeTranscriptStore()
    store.appendError = StoreFailure()
    let vm = LiveTranscriptionViewModel(engine: engine, transcriptStore: store)
    await vm.start()

    engine.push(.segment(makeSegment("Maintain present heading.")))
    #expect(await wait(for: { vm.segments.count == 1 && vm.persistenceFailure != nil }))

    #expect(vm.visibleSegments.count == 1)
    #expect(vm.status == .listening)
  }

  @Test func persistenceEndsSessionOnFailedStatus() async {
    let engine = FakeEngine()
    let store = FakeTranscriptStore()
    let vm = LiveTranscriptionViewModel(engine: engine, transcriptStore: store)
    await vm.start()
    #expect(await wait(for: { store.beginLocaleIdentifiers.count == 1 }))

    engine.push(.status(.failed("asr-error:kLSRErrorDomain#300")))
    #expect(await wait(for: { store.endedSessionIDs.count == 1 }))
  }

  @Test func duplicateStartWhileStartInFlightDoesNotCallEngineTwice() async {
    let engine = FakeEngine(startSuspends: true)
    let vm = LiveTranscriptionViewModel(engine: engine)
    let firstStart = Task { @MainActor in await vm.start() }

    #expect(await wait(for: { engine.startCallCount == 1 && vm.canStopCurrentSession }))

    await vm.start()

    #expect(engine.startCallCount == 1)

    engine.completeStart()
    await firstStart.value
    #expect(await wait(for: { vm.isListening && vm.canStopCurrentSession }))
    #expect(vm.isListening)
    #expect(vm.canStopCurrentSession)
  }

  @Test func stopDuringStartInFlightCancelsCurrentSession() async {
    let engine = FakeEngine(startSuspends: true)
    let vm = LiveTranscriptionViewModel(engine: engine)
    let firstStart = Task { @MainActor in await vm.start() }

    #expect(await wait(for: { engine.startCallCount == 1 && vm.canStopCurrentSession }))

    vm.stop()

    #expect(engine.stopCallCount == 1)
    #expect(await wait(for: { vm.status == .stopped && !vm.canStopCurrentSession }))

    engine.completeStart()
    await firstStart.value
    #expect(engine.startCallCount == 1)
    #expect(vm.status == .stopped)
    #expect(!vm.canStopCurrentSession)
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

  @Test func visibleSegmentsCapsLastFiveHundredAndCountsOlderHistory() async {
    let engine = FakeEngine()
    let vm = LiveTranscriptionViewModel(engine: engine)
    await vm.start()

    for index in 0..<10_050 {
      engine.push(.segment(makeSegment("Transmission \(index)")))
    }
    #expect(await wait(for: { vm.segments.count == 10_050 }))

    #expect(vm.visibleSegments.count == 500)
    #expect(vm.olderSegmentCountInHistory == 9_550)
    #expect(vm.visibleSegments.first?.text == "Transmission 9550")
    #expect(vm.visibleSegments.last?.text == "Transmission 10049")
  }

  @Test func unhideSuppressedSegmentKeepsIndicator() async throws {
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
    engine.push(.segment(makeSegment("Delta 45 monitor tower")))
    #expect(await wait(for: { vm.suppressedSegmentIDs.count == 2 }))
    let hiddenID = try #require(vm.segments.first?.id)

    vm.unhideSuppressedSegment(id: hiddenID)

    #expect(!vm.suppressedSegmentIDs.contains(hiddenID))
    #expect(vm.visibleSegments.contains { $0.id == hiddenID })
    #expect(vm.indicator(for: try #require(vm.segments.first)) == .otherTrafficSuppressed)
  }

  @Test func unhideAllSuppressedSegmentsKeepsIndicators() async throws {
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
    engine.push(.segment(makeSegment("Delta 45 monitor tower")))
    #expect(await wait(for: { vm.suppressedSegmentIDs.count == 2 }))
    let first = try #require(vm.segments.first)

    vm.unhideAllSuppressedSegments()

    #expect(vm.suppressedSegmentIDs.isEmpty)
    #expect(vm.visibleSegments.count == 2)
    #expect(vm.indicator(for: first) == .otherTrafficSuppressed)
  }

  // MARK: - Translation orchestration (F3)

  private func translatingVM(
    engine: FakeEngine,
    backend: any TranslationService,
    target: String?
  ) -> LiveTranscriptionViewModel {
    LiveTranscriptionViewModel(
      engine: engine,
      translator: backend,
      translationTarget: { target.map { Locale.Language(identifier: $0) } }
    )
  }

  // why: test cases are serialized, and NSLock protects the suspended translation
  // and completion waiters that are resumed across task boundaries.
  final class CompletionTrackingTranslationBackend: TranslationService, @unchecked Sendable {
    var translationResult = "STALE"
    private(set) var translateCallCount = 0
    private(set) var recordedInputs: [String] = []

    private struct CompletionWaiter {
      let completedAfter: Int
      let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var completionWaiters: [CompletionWaiter] = []
    private var completedCount = 0

    var completedTranslationCount: Int {
      lock.lock()
      let value = completedCount
      lock.unlock()
      return value
    }

    func availability(
      translatingFrom source: Locale.Language,
      into target: Locale.Language
    ) async -> TranslationLanguageStatus {
      .installed
    }

    func translate(
      _ text: String,
      from source: Locale.Language,
      into target: Locale.Language
    ) async throws(TranslationServiceError) -> String {
      translateCallCount += 1
      recordedInputs.append(text)
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        lock.lock()
        pending.append(continuation)
        lock.unlock()
      }
      let result = translationResult
      completeOneTranslation()
      return result
    }

    func releaseAll() {
      lock.lock()
      let continuations = pending
      pending.removeAll()
      lock.unlock()
      for continuation in continuations { continuation.resume() }
    }

    func waitForCompletion(after completedBeforeRelease: Int) async {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        lock.lock()
        if completedCount > completedBeforeRelease {
          lock.unlock()
          continuation.resume()
        } else {
          completionWaiters.append(
            CompletionWaiter(
              completedAfter: completedBeforeRelease,
              continuation: continuation
            ))
          lock.unlock()
        }
      }
    }

    private func completeOneTranslation() {
      let ready: [CheckedContinuation<Void, Never>]
      lock.lock()
      completedCount += 1
      var remaining: [CompletionWaiter] = []
      var resumable: [CheckedContinuation<Void, Never>] = []
      for waiter in completionWaiters {
        if completedCount > waiter.completedAfter {
          resumable.append(waiter.continuation)
        } else {
          remaining.append(waiter)
        }
      }
      completionWaiters = remaining
      ready = resumable
      lock.unlock()
      for continuation in ready { continuation.resume() }
    }
  }

  private func expectTranslationFailure(
    _ error: TranslationServiceError,
    expected: TranslationFailure
  ) async {
    let engine = FakeEngine()
    let backend = FakeTranslationBackend()
    backend.translateError = error
    let vm = translatingVM(engine: engine, backend: backend, target: "ru")
    await vm.start()
    let seg = makeSegment("Descend")
    engine.push(.segment(seg))
    #expect(await wait(for: { vm.translationFailure == expected }))
    #expect(vm.translations[seg.id] == nil)
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
    engine.push(.partial("translation barrier after same-source segment"))
    #expect(await wait(for: { vm.partialText == "translation barrier after same-source segment" }))
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
    engine.push(.partial("translation barrier after disabled segment"))
    #expect(await wait(for: { vm.partialText == "translation barrier after disabled segment" }))
    #expect(backend.translateCallCount == 0)
  }

  @Test func missingLanguagePackMarksUnavailable() async {
    let engine = FakeEngine()
    let backend = FakeTranslationBackend()
    let expected = TranslationFailure.languagePackNotInstalled(
      source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "ru"))
    backend.translateError = .languagePackNotInstalled(
      source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "ru"))
    let vm = translatingVM(engine: engine, backend: backend, target: "ru")
    await vm.start()
    let seg = makeSegment("Descend")
    engine.push(.segment(seg))
    #expect(await wait(for: { vm.translationFailure == expected }))
    #expect(vm.translationUnavailable)
    #expect(vm.translations[seg.id] == nil)
  }

  @Test func unsupportedSourceLanguageMarksVisibleFailure() async {
    let source = Locale.Language(identifier: "zz")
    await expectTranslationFailure(
      .sourceLanguageUnsupported(source),
      expected: .sourceLanguageUnsupported(source))
  }

  @Test func unsupportedTargetLanguageMarksVisibleFailure() async {
    let target = Locale.Language(identifier: "zz")
    await expectTranslationFailure(
      .targetLanguageUnsupported(target),
      expected: .targetLanguageUnsupported(target))
  }

  @Test func unsupportedLanguagePairMarksVisibleFailure() async {
    let source = Locale.Language(identifier: "en")
    let target = Locale.Language(identifier: "ru")
    await expectTranslationFailure(
      .languagePairingUnsupported(source: source, target: target),
      expected: .languagePairingUnsupported(source: source, target: target))
  }

  @Test func emptyTranslationInputMarksVisibleFailure() async {
    await expectTranslationFailure(.emptyInput, expected: .emptyInput)
  }

  @Test func cancelledTranslationSessionMarksVisibleFailure() async {
    await expectTranslationFailure(.sessionCancelled, expected: .sessionCancelled)
  }

  @Test func engineTranslationFailureMarksVisibleFailure() async {
    await expectTranslationFailure(
      .engineFailure("backend-token-42"),
      expected: .engineFailure("backend-token-42"))
  }

  @Test func successfulTranslationClearsPreviousFailure() async {
    let engine = FakeEngine()
    let backend = FakeTranslationBackend()
    backend.translateError = .engineFailure("first-failure")
    let vm = translatingVM(engine: engine, backend: backend, target: "ru")
    await vm.start()
    engine.push(.segment(makeSegment("Descend")))
    #expect(await wait(for: { vm.translationFailure == .engineFailure("first-failure") }))

    backend.translateError = nil
    backend.translationResult = "перевод"
    let recovered = makeSegment("Maintain three thousand")
    engine.push(.segment(recovered))

    #expect(await wait(for: { vm.translations[recovered.id] == "перевод" }))
    #expect(vm.translationFailure == nil)
  }

  @Test func clearTranslationsClearsTranslationFailure() async {
    let engine = FakeEngine()
    let backend = FakeTranslationBackend()
    backend.translateError = .engineFailure("failure")
    let vm = translatingVM(engine: engine, backend: backend, target: "ru")
    await vm.start()
    engine.push(.segment(makeSegment("Descend")))
    #expect(await wait(for: { vm.translationFailure == .engineFailure("failure") }))

    vm.clearTranslations()

    #expect(vm.translationFailure == nil)
    #expect(vm.translations.isEmpty)
  }

  @Test func preparationFailureIsRecorded() {
    let engine = FakeEngine()
    let backend = FakeTranslationBackend()
    let vm = translatingVM(engine: engine, backend: backend, target: "ru")

    let token = vm.beginTranslationPreparation()
    vm.recordTranslationPreparationFailure(.preparationFailed("download-token-42"), token: token)

    #expect(vm.translationFailure == .preparationFailed("download-token-42"))
  }

  @Test func stalePreparationFailureAfterClearTranslationsIsIgnored() {
    let engine = FakeEngine()
    let backend = FakeTranslationBackend()
    let vm = translatingVM(engine: engine, backend: backend, target: "ru")

    let staleToken = vm.beginTranslationPreparation()
    vm.clearTranslations()
    vm.recordTranslationPreparationFailure(.preparationFailed("stale-download"), token: staleToken)

    #expect(vm.translationFailure == nil)
  }

  @Test func newPreparationClearsPreviousTranslationFailure() {
    let engine = FakeEngine()
    let backend = FakeTranslationBackend()
    let vm = translatingVM(engine: engine, backend: backend, target: "ru")

    let token = vm.beginTranslationPreparation()
    vm.recordTranslationPreparationFailure(.preparationFailed("old-download"), token: token)
    #expect(vm.translationFailure == .preparationFailed("old-download"))

    _ = vm.beginTranslationPreparation()

    #expect(vm.translationFailure == nil)
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
    #expect(vm.translationFailure == nil)
  }

  @Test func retranslateAllRetranslatesExistingSegments() async {
    let engine = FakeEngine()
    let backend = FakeTranslationBackend()
    backend.translationResult = "перевод"
    let vm = translatingVM(engine: engine, backend: backend, target: "ru")
    await vm.start()
    let seg = makeSegment("Descend")
    engine.push(.segment(seg))
    #expect(await wait(for: { vm.translations[seg.id] == "перевод" }))
    let firstCount = backend.translateCallCount
    backend.translationResult = "новый перевод"
    vm.retranslateAll()
    #expect(await wait(for: { vm.translations[seg.id] == "новый перевод" }))
    #expect(backend.translateCallCount > firstCount)
  }

  @Test func taskSupersededByResetDoesNotWriteStaleGloss() async {
    let engine = FakeEngine()
    let backend = CompletionTrackingTranslationBackend()
    let vm = translatingVM(engine: engine, backend: backend, target: "ru")
    await vm.start()
    let seg = makeSegment("Descend")
    engine.push(.segment(seg))
    // the translation task is in-flight, suspended inside translate before it writes
    #expect(await wait(for: { backend.translateCallCount == 1 }))
    #expect(vm.translations[seg.id] == nil)

    vm.reset()  // clears the per-segment token; the in-flight task is now superseded
    let completedBeforeRelease = backend.completedTranslationCount
    backend.releaseAll()  // task resumes and returns "STALE", but its token no longer matches
    await backend.waitForCompletion(after: completedBeforeRelease)

    // would land if the token guard were missing; with it, the stale write is dropped
    #expect(vm.translations.isEmpty)
  }
}
