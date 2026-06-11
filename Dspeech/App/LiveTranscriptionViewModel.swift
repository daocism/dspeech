import Foundation
import Observation

@MainActor
@Observable
final class LiveTranscriptionViewModel {
  private(set) var segments: [TranscriptSegment] = []
  private(set) var partialText: String = ""
  private(set) var status: LiveTranscriptionStatus = .idle
  private(set) var filterIndicators: [UUID: ATCVoiceIndicator] = [:]
  private(set) var suppressedSegmentIDs: Set<UUID> = []
  private(set) var translations: [UUID: String] = [:]
  private(set) var translationFailure: TranslationFailure?
  private(set) var persistenceFailure: String?
  // why: the demo/mockup transcript is a first-run illustration only. Once the user has
  // started a real session it must never reappear over (or instead of) real content — the
  // "press Stop and the transcript turns back into demo" confusion.
  private(set) var hasEverStarted = false

  private let engine: any LiveTranscriptionEngine
  private let transcriptStore: (any TranscriptStoring)?
  private let recognitionLocaleIdentifier: @MainActor () -> String?
  private let firstSessionStorage: any FirstSessionStateStorage
  private let voiceFilter: VoiceFilterPipeline?
  private let translator: (any TranslationService)?
  private let translationTarget: @MainActor () -> Locale.Language?
  private var eventTask: Task<Void, Never>?
  private var translationTasks: [UUID: Task<Void, Never>] = [:]
  private var translationTaskTokens: [UUID: UUID] = [:]
  private var translationPreparationToken = UUID()
  private var startInFlight = false
  private var activeTranscriptSessionID: UUID?
  private var persistenceUnavailableForCurrentSession = false
  // why: a Stop-committed partial has no language of its own; reuse the last real segment's
  // language, defaulting to the device language (matches the device-language default policy).
  private var lastSourceLanguageCode = String(
    Locale.current.language.languageCode?.identifier ?? "en")

  init(
    engine: any LiveTranscriptionEngine,
    transcriptStore: (any TranscriptStoring)? = nil,
    recognitionLocaleIdentifier: @escaping @MainActor () -> String? = { nil },
    firstSessionStorage: any FirstSessionStateStorage = UserDefaultsFirstSessionStateStorage(),
    voiceFilter: VoiceFilterPipeline? = nil,
    translator: (any TranslationService)? = nil,
    translationTarget: @escaping @MainActor () -> Locale.Language? = { nil }
  ) {
    self.engine = engine
    self.transcriptStore = transcriptStore
    self.recognitionLocaleIdentifier = recognitionLocaleIdentifier
    self.firstSessionStorage = firstSessionStorage
    self.voiceFilter = voiceFilter
    self.translator = translator
    self.translationTarget = translationTarget
    self.hasEverStarted = firstSessionStorage.loadHasEverStarted()
  }

  var visibleSegments: [TranscriptSegment] {
    guard !suppressedSegmentIDs.isEmpty else { return segments }
    return segments.filter { !suppressedSegmentIDs.contains($0.id) }
  }

  func indicator(for segment: TranscriptSegment) -> ATCVoiceIndicator? {
    filterIndicators[segment.id]
  }

  var voiceFilterCapability: VoiceFilterCapability? {
    voiceFilter?.capability
  }

  var isListening: Bool {
    status == .listening
  }

  var canStopCurrentSession: Bool {
    startInFlight || status == .requestingPermission || status == .listening
  }

  var lastErrorMessage: String? {
    if case .failed(let message) = status { return message }
    return nil
  }

  var translationUnavailable: Bool {
    if case .languagePackNotInstalled = translationFailure { return true }
    return false
  }

  func start() async {
    guard !canStopCurrentSession else { return }
    startInFlight = true
    defer { startInFlight = false }
    if !hasEverStarted {
      hasEverStarted = true
      firstSessionStorage.saveHasEverStarted(true)
    }
    if eventTask == nil {
      startObservingEvents()
    }
    await engine.start()
  }

  func stop() {
    startInFlight = false
    // why: pressing Stop must NOT discard what the user was watching. If a partial line is
    // still on screen (the recognizer hasn't finalized it), commit it as a segment so the
    // transcript persists instead of vanishing on teardown.
    commitPartialAsSegment()
    engine.stop()
  }

  private func commitPartialAsSegment() {
    let text = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    partialText = ""
    // why: confidence 0 = "unverified" — the recognizer never confirmed this line. The card
    // hides the meaningless 0% and shows the VERIFY badge, which is the honest signal.
    append(
      segment: TranscriptSegment(
        text: text,
        confidence: 0,
        sourceLanguageCode: lastSourceLanguageCode,
        source: .liveATC))
  }

  func reset() {
    endPersistenceSessionIfNeeded()
    segments.removeAll()
    partialText = ""
    filterIndicators.removeAll()
    suppressedSegmentIDs.removeAll()
    clearTranslations()
  }

  func dismissPersistenceFailure() {
    persistenceFailure = nil
  }

  func recordPersistenceUnavailable() {
    recordPersistenceFailure()
  }

  func unhideSuppressedSegment(id: UUID) {
    suppressedSegmentIDs.remove(id)
  }

  func unhideAllSuppressedSegments() {
    suppressedSegmentIDs.removeAll()
  }

  func clearTranslations() {
    translationPreparationToken = UUID()
    for task in translationTasks.values { task.cancel() }
    translationTasks.removeAll()
    translationTaskTokens.removeAll()
    translations.removeAll()
    translationFailure = nil
  }

  func beginTranslationPreparation() -> UUID {
    let token = UUID()
    translationPreparationToken = token
    translationFailure = nil
    return token
  }

  func recordTranslationPreparationFailure(_ failure: TranslationFailure, token: UUID) {
    guard token == translationPreparationToken else { return }
    translationFailure = failure
  }

  func retranslateAll() {
    clearTranslations()
    for segment in segments { maybeTranslate(segment) }
  }

  private func maybeTranslate(_ segment: TranscriptSegment) {
    guard let translator, let target = translationTarget() else { return }
    let source = Locale.Language(identifier: segment.sourceLanguageCode)
    // why: skip a same-language no-op (en->en) so the gloss doesn't echo the transcript.
    if let from = source.languageCode?.identifier,
      let to = target.languageCode?.identifier, from == to
    {
      return
    }
    let id = segment.id
    let text = segment.text
    translationTasks[id]?.cancel()
    let token = UUID()
    translationTaskTokens[id] = token
    translationTasks[id] = Task { @MainActor [weak self] in
      guard let self else { return }
      // why: clear the slot only if this task still owns it — a superseding task
      // (retranslate / target change) may have replaced it after this was cancelled.
      defer {
        if self.translationTaskTokens[id] == token {
          self.translationTasks[id] = nil
          self.translationTaskTokens[id] = nil
        }
      }
      let result: String
      do {
        result = try await translator.translate(text, from: source, into: target)
      } catch let error as TranslationServiceError {
        if self.translationTaskTokens[id] == token {
          self.translationFailure = .service(error)
        }
        return
      } catch {
        if self.translationTaskTokens[id] == token {
          self.translationFailure = .engineFailure(String(describing: error))
        }
        return
      }
      guard self.translationTaskTokens[id] == token else { return }
      self.translations[id] = result
      self.translationFailure = nil
    }
  }

  private func append(segment: TranscriptSegment) {
    if !segment.sourceLanguageCode.isEmpty { lastSourceLanguageCode = segment.sourceLanguageCode }
    let segmentToPersist: TranscriptSegment
    // why: the recognizer can emit a real final for the SAME utterance a beat AFTER Stop already
    // committed it as a confidence-0 placeholder (commitPartialAsSegment). Replace the placeholder
    // in place rather than showing the line twice — one VERIFY card and one identical confirmed
    // card. A confidence-0 .liveATC segment is only ever a Stop placeholder, so this can't collide
    // with a legitimately repeated utterance mid-session.
    if segment.confidence > 0, segment.source == .liveATC,
      let last = segments.last, last.source == .liveATC, last.confidence == 0,
      last.text.caseInsensitiveCompare(segment.text) == .orderedSame
    {
      clearDerivedState(for: last.id)
      segments[segments.count - 1] = segment
      segmentToPersist = segment
    } else {
      segments.append(segment)
      segmentToPersist = segment
    }
    persist(segment: segmentToPersist)
    maybeTranslate(segment)
    applyVoiceFilter(to: segment)
  }

  private func applyVoiceFilter(to segment: TranscriptSegment) {
    guard let pipeline = voiceFilter, pipeline.enabled else { return }
    // Phase 1 (ADR 0007): no real speaker classifier — treat every segment as
    // non-pilot so the callsign-relevance gate (ATCTranscriptGate) can decide.
    // Phase 2 will replace `.nonPilot` with the FluidAudio-backed classifier output.
    let decision = pipeline.decide(
      text: segment.text,
      speaker: .nonPilot(bestPilotScore: 0),
      timestamp: segment.startedAt
    )
    filterIndicators[segment.id] = decision.indicator
    if case .suppress = decision.relevance {
      suppressedSegmentIDs.insert(segment.id)
    }
  }

  private func clearDerivedState(for id: UUID) {
    filterIndicators[id] = nil
    suppressedSegmentIDs.remove(id)
    translations[id] = nil
    translationTasks[id]?.cancel()
    translationTasks[id] = nil
    translationTaskTokens[id] = nil
  }

  private func startObservingEvents() {
    let stream = engine.events()
    eventTask = Task { @MainActor [weak self] in
      for await event in stream {
        guard let self else { return }
        switch event {
        case .partial(let text):
          self.partialText = text
        case .segment(let segment):
          self.append(segment: segment)
          self.partialText = ""
        case .status(let newStatus):
          let oldStatus = self.status
          self.status = newStatus
          if oldStatus != .listening, newStatus == .listening {
            self.beginPersistenceSessionIfNeeded()
          }
          if newStatus == .stopped {
            self.partialText = ""
            self.endPersistenceSessionIfNeeded()
          }
          if case .failed = newStatus {
            self.endPersistenceSessionIfNeeded()
          }
        }
      }
    }
  }

  private func beginPersistenceSessionIfNeeded() {
    guard let transcriptStore,
      activeTranscriptSessionID == nil,
      !persistenceUnavailableForCurrentSession
    else {
      return
    }
    let localeIdentifier = recognitionLocaleIdentifier() ?? Locale.current.identifier
    do {
      let session = try transcriptStore.beginSession(localeIdentifier: localeIdentifier)
      activeTranscriptSessionID = session.id
    } catch {
      persistenceUnavailableForCurrentSession = true
      recordPersistenceFailure()
    }
  }

  private func persist(segment: TranscriptSegment) {
    guard segment.source == .liveATC, let transcriptStore else { return }
    if activeTranscriptSessionID == nil, status == .listening {
      beginPersistenceSessionIfNeeded()
    }
    guard let activeTranscriptSessionID else { return }
    do {
      try transcriptStore.append(segment, to: activeTranscriptSessionID)
    } catch {
      recordPersistenceFailure()
    }
  }

  private func endPersistenceSessionIfNeeded() {
    defer {
      activeTranscriptSessionID = nil
      persistenceUnavailableForCurrentSession = false
    }
    guard let activeTranscriptSessionID, let transcriptStore else { return }
    do {
      try transcriptStore.endSession(activeTranscriptSessionID)
    } catch {
      recordPersistenceFailure()
    }
  }

  private func recordPersistenceFailure() {
    // why: persistence is flight-data durability, but capture is the primary safety path.
    // A store failure warns the pilot without stopping or hiding the live ATC transcript.
    persistenceFailure = String(
      localized: "Couldn't save the transcript. Live transcription continues.")
  }

  #if DEBUG
    func seedSuppressedDemoSegmentForUITests() {
      let segment = TranscriptSegment(
        startedAt: Date(timeIntervalSince1970: 1_000),
        text: "Speedbird 42, contact tower one one eight decimal seven.",
        confidence: 0.92,
        sourceLanguageCode: "en",
        source: .demo
      )
      segments = [segment]
      filterIndicators = [segment.id: .otherTrafficSuppressed]
      suppressedSegmentIDs = [segment.id]
      // why: in-memory only — persisting the flag from a UI-test seed would leak
      // first-run state across UI tests and make them order-dependent.
      hasEverStarted = true
    }
  #endif
}
