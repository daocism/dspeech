import Foundation
import Observation

protocol NoAnchorHintStateStorage: Sendable {
  func loadHasShownNoAnchorHint() -> Bool
  func saveHasShownNoAnchorHint(_ hasShown: Bool)
}

struct UserDefaultsNoAnchorHintStateStorage: NoAnchorHintStateStorage, @unchecked Sendable {
  static let hasShownKey = "dspeech.transmission.no-anchor-hint-shown.v1"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func loadHasShownNoAnchorHint() -> Bool {
    defaults.bool(forKey: Self.hasShownKey)
  }

  func saveHasShownNoAnchorHint(_ hasShown: Bool) {
    defaults.set(hasShown, forKey: Self.hasShownKey)
  }
}

@MainActor
@Observable
final class LiveTranscriptionViewModel {
  private static let visibleSegmentLimit = 500

  private(set) var segments: [TranscriptSegment] = []
  private(set) var displayedTransmissions: [Transmission] = []
  private(set) var filteredTransmissions: [Transmission] = []
  private(set) var partialText: String = ""
  private(set) var status: LiveTranscriptionStatus = .idle
  private(set) var suppressedSegmentIDs: Set<UUID> = []
  private(set) var translations: [UUID: String] = [:]
  private(set) var translationFailure: TranslationFailure?
  private(set) var persistenceFailure: String?
  // why: the demo/mockup transcript is a first-run illustration only. Once the user has
  // started a real session it must never reappear over (or instead of) real content — the
  // "press Stop and the transcript turns back into demo" confusion.
  private(set) var hasEverStarted = false
  var oneTimeNoAnchorHintVisible = false

  private let engine: any LiveTranscriptionEngine
  private let transcriptStore: (any TranscriptStoring)?
  private let recognitionLocaleIdentifier: @MainActor () -> String?
  private let recognitionTransmissionGapSeconds: @MainActor () -> TimeInterval
  private let firstSessionStorage: any FirstSessionStateStorage
  private let noAnchorHintStorage: any NoAnchorHintStateStorage
  private let voiceFilter: VoiceFilterPipeline?
  private let translator: (any TranslationService)?
  private let translationTarget: @MainActor () -> Locale.Language?
  private let now: @MainActor () -> Date
  private let transmissionTickNanoseconds: UInt64
  // why: cap on the RAM-resident transmission cards (the disk store keeps the full record). Far
  // above the 500 visible-segment cap so live scrollback never hits the eviction boundary; older
  // content lives in Session History.
  private let transmissionWindowLimit: Int
  // why: displayable segments already EVICTED from the RAM window — added so
  // olderSegmentCountInHistory reflects the full on-disk record, not just resident segments.
  private var evictedDisplayableSegmentCount = 0
  // why: segment.id -> owning transmission.id. Eviction drops a segment's derived state only when
  // the transmission that owns it is itself evicted, never stripping a still-retained card's data.
  private var segmentOwner: [UUID: UUID] = [:]
  private var eventTask: Task<Void, Never>?
  private var transmissionTickTask: Task<Void, Never>?
  private var transmissionAssembler: TransmissionAssembler?
  private var translationTasks: [UUID: Task<Void, Never>] = [:]
  private var translationTaskTokens: [UUID: UUID] = [:]
  private var translationPreparationToken = UUID()
  private var startInFlight = false
  private var activeTranscriptSessionID: UUID?
  private var mostRecentTranscriptSessionID: UUID?
  private var persistenceUnavailableForCurrentSession = false
  // why: a Stop-committed partial has no language of its own; reuse the last real segment's
  // language, defaulting to the device language (matches the device-language default policy).
  private var lastSourceLanguageCode = Locale.current.language.languageCode?.identifier ?? "en"
  private var hasShownNoAnchorHint: Bool

  init(
    engine: any LiveTranscriptionEngine,
    transcriptStore: (any TranscriptStoring)? = nil,
    recognitionLocaleIdentifier: @escaping @MainActor () -> String? = { nil },
    recognitionTransmissionGapSeconds: @escaping @MainActor () -> TimeInterval = { 2.0 },
    firstSessionStorage: any FirstSessionStateStorage = UserDefaultsFirstSessionStateStorage(),
    noAnchorHintStorage: any NoAnchorHintStateStorage = UserDefaultsNoAnchorHintStateStorage(),
    voiceFilter: VoiceFilterPipeline? = nil,
    translator: (any TranslationService)? = nil,
    translationTarget: @escaping @MainActor () -> Locale.Language? = { nil },
    now: @escaping @MainActor () -> Date = { Date() },
    transmissionTickNanoseconds: UInt64 = 500_000_000,
    transmissionWindowLimit: Int = 2_000
  ) {
    self.engine = engine
    self.transcriptStore = transcriptStore
    self.recognitionLocaleIdentifier = recognitionLocaleIdentifier
    self.recognitionTransmissionGapSeconds = recognitionTransmissionGapSeconds
    self.firstSessionStorage = firstSessionStorage
    self.noAnchorHintStorage = noAnchorHintStorage
    self.voiceFilter = voiceFilter
    self.translator = translator
    self.translationTarget = translationTarget
    self.now = now
    self.transmissionTickNanoseconds = transmissionTickNanoseconds
    self.transmissionWindowLimit = transmissionWindowLimit
    self.hasEverStarted = firstSessionStorage.loadHasEverStarted()
    self.hasShownNoAnchorHint = noAnchorHintStorage.loadHasShownNoAnchorHint()
  }

  var visibleSegments: [TranscriptSegment] {
    let displayable = displayableSegments
    guard displayable.count > Self.visibleSegmentLimit else { return displayable }
    return Array(displayable.suffix(Self.visibleSegmentLimit))
  }

  var olderSegmentCountInHistory: Int {
    // why: include displayable segments already EVICTED from the RAM window so this reflects the
    // full on-disk record (evicted + resident), not just what is currently in memory.
    max(evictedDisplayableSegmentCount + displayableSegments.count - Self.visibleSegmentLimit, 0)
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
    // why: a Stop-commit of the in-flight partial has no settled speaker classification;
    // pass nil so the gate fails open (shows it) rather than risk suppressing a real call.
    handleFinalSegment(
      TranscriptSegment(
        text: text,
        confidence: 0,
        sourceLanguageCode: lastSourceLanguageCode,
        source: .liveATC,
        isStopCommittedPlaceholder: true),
      speaker: nil)
  }

  func reset() {
    stopTransmissionTickLoop()
    endPersistenceSessionIfNeeded()
    mostRecentTranscriptSessionID = nil
    segments.removeAll()
    displayedTransmissions.removeAll()
    filteredTransmissions.removeAll()
    transmissionAssembler = nil
    partialText = ""
    oneTimeNoAnchorHintVisible = false
    suppressedSegmentIDs.removeAll()
    segmentOwner.removeAll()
    evictedDisplayableSegmentCount = 0
    clearTranslations()
  }

  func dismissPersistenceFailure() {
    persistenceFailure = nil
  }

  func dismissNoAnchorHint() {
    oneTimeNoAnchorHintVisible = false
  }

  func recordPersistenceUnavailable() {
    recordPersistenceFailure()
  }

  // why: durability checkpoint for the transcript store's deferred-fsync model — called from the
  // background hook so the page-cache-durable appends are fsync'd before the app can be suspended.
  func flushPersistence() {
    guard let transcriptStore else { return }
    do {
      try transcriptStore.flush()
    } catch {
      recordPersistenceFailure()
    }
  }

  func showFilteredTransmission(id: UUID) {
    guard let index = filteredTransmissions.firstIndex(where: { $0.id == id }) else { return }
    let transmission = filteredTransmissions.remove(at: index)
    displayedTransmissions.append(transmission)
    evictOldestTransmissions(from: &displayedTransmissions)
  }

  func unhideAllSuppressedSegments() {
    suppressedSegmentIDs.removeAll()
    displayedTransmissions.append(contentsOf: filteredTransmissions)
    filteredTransmissions.removeAll()
    evictOldestTransmissions(from: &displayedTransmissions)
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

  private func append(segment: TranscriptSegment, speaker: SpeakerMatchDecision?) {
    if !segment.sourceLanguageCode.isEmpty { lastSourceLanguageCode = segment.sourceLanguageCode }
    let segmentToPersist: TranscriptSegment
    let replacementPersistenceSessionID: UUID?
    // why: the recognizer can emit a real final for the SAME utterance a beat AFTER Stop already
    // committed it as an unverified placeholder. Replace only that explicitly-marked placeholder;
    // confidence 0 can be a real Apple Speech final and must not be used as object identity.
    if !segment.isStopCommittedPlaceholder, segment.source == .liveATC,
      let last = segments.last, last.source == .liveATC, last.isStopCommittedPlaceholder,
      last.text.caseInsensitiveCompare(segment.text) == .orderedSame
    {
      clearDerivedState(for: last.id)
      segments[segments.count - 1] = segment
      segmentToPersist = segment
      replacementPersistenceSessionID = activeTranscriptSessionID ?? mostRecentTranscriptSessionID
    } else {
      segments.append(segment)
      segmentToPersist = segment
      replacementPersistenceSessionID = nil
    }
    persist(segment: segmentToPersist, fallbackSessionID: replacementPersistenceSessionID)
    maybeTranslate(segment)
    applyVoiceFilter(to: segment, speaker: speaker)
  }

  private func handleFinalSegment(_ segment: TranscriptSegment, speaker: SpeakerMatchDecision?) {
    append(segment: segment, speaker: speaker)
    guard segment.source == .liveATC,
      status == .listening || activeTranscriptSessionID != nil
    else {
      return
    }
    processTransmissionInput(.fragment(segment: segment, speaker: speaker, at: now()))
  }

  private func processTransmissionInput(_ input: TransmissionAssemblerInput) {
    if transmissionAssembler == nil {
      transmissionAssembler = makeTransmissionAssembler()
    }
    guard var assembler = transmissionAssembler else { return }
    let updates = assembler.process(input)
    transmissionAssembler = assembler
    applyTransmissionUpdates(updates)
  }

  private func finishTransmissionAssembly(at date: Date) {
    guard var assembler = transmissionAssembler else { return }
    let updates = assembler.finish(at: date)
    transmissionAssembler = assembler
    applyTransmissionUpdates(updates)
  }

  private func makeTransmissionAssembler() -> TransmissionAssembler {
    let localeIdentifier = recognitionLocaleIdentifier() ?? Locale.current.identifier
    var classifier = TransmissionClassifier(
      configuredCallSign: voiceFilter?.callSign,
      localeIdentifier: localeIdentifier,
      voicePackActive: voicePackActive
    )
    return TransmissionAssembler(
      config: TransmissionAssemblerConfig(
        transmissionGapSeconds: recognitionTransmissionGapSeconds()),
      localeIdentifier: localeIdentifier,
      classify: { text, speakers, endedAt in
        classifier.classify(text: text, speakers: speakers, endedAt: endedAt)
      }
    )
  }

  private var voicePackActive: Bool {
    guard let voiceFilter, voiceFilter.enabled, !voiceFilter.profiles.isEmpty else { return false }
    if case .ready = voiceFilter.capability { return true }
    return false
  }

  private func applyTransmissionUpdates(_ updates: [TransmissionUpdate]) {
    for update in updates {
      let transmission = update.transmission
      upsertTransmission(transmission)
      persist(transmissionUpdate: update)
      maybeShowNoAnchorHint(for: transmission)
    }
  }

  private func upsertTransmission(_ transmission: Transmission) {
    // why: an open transmission is upserted every tick; scanning BOTH arrays to remove its prior
    // copy was O(n) per tick. The hot path (updating the still-open transmission, which sits at the
    // tail of its array) is now O(1); only a rare reclassification falls back to a full scan.
    removeExistingTransmission(id: transmission.id)
    let display = compactingCallSign(in: transmission)
    guard !display.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }
    for segment in display.segments { segmentOwner[segment.id] = display.id }
    switch display.classification {
    case .displayed:
      displayedTransmissions.append(display)
      evictOldestTransmissions(from: &displayedTransmissions)
    case .filtered:
      filteredTransmissions.append(display)
      evictOldestTransmissions(from: &filteredTransmissions)
    }
  }

  private func removeExistingTransmission(id: UUID) {
    if displayedTransmissions.last?.id == id {
      displayedTransmissions.removeLast()
    } else if filteredTransmissions.last?.id == id {
      filteredTransmissions.removeLast()
    } else if displayedTransmissions.contains(where: { $0.id == id }) {
      displayedTransmissions.removeAll { $0.id == id }
    } else {
      filteredTransmissions.removeAll { $0.id == id }
    }
  }

  // why: cap the RAM-resident card list (the disk store keeps the full record). Evict oldest-first
  // and cascade to each evicted card's segments + per-segment derived state, so the bound is real
  // rather than cosmetic. Older content remains available through Session History.
  private func evictOldestTransmissions(from transmissions: inout [Transmission]) {
    while transmissions.count > transmissionWindowLimit {
      evictDerivedState(for: transmissions.removeFirst())
    }
  }

  private func evictDerivedState(for transmission: Transmission) {
    // why: only drop a segment whose CURRENT owner is the transmission being evicted — never strip
    // state still referenced by a retained card (1:1 ownership today; the guard is insurance).
    let evictableIDs = transmission.segments.map(\.id).filter {
      segmentOwner[$0] == transmission.id
    }
    guard !evictableIDs.isEmpty else { return }
    let evictableSet = Set(evictableIDs)
    for id in evictableIDs {
      if !suppressedSegmentIDs.contains(id) { evictedDisplayableSegmentCount += 1 }
      suppressedSegmentIDs.remove(id)
      translations[id] = nil
      translationTasks[id]?.cancel()
      translationTasks[id] = nil
      translationTaskTokens[id] = nil
      segmentOwner[id] = nil
    }
    segments.removeAll { evictableSet.contains($0.id) }
  }

  // why: DISPLAY the operator's own call sign as the compact registration ("A123B"), not its
  // spoken ICAO phonetics ("Alpha 1 2 3 Bravo"). Detection/classification still runs on the raw
  // transcript (in the assembler), so this only changes what the pilot reads on the card.
  private func compactingCallSign(in transmission: Transmission) -> Transmission {
    guard let callSign = voiceFilter?.callSign else { return transmission }
    let compacted = callSign.compacted(
      in: transmission.text, localeIdentifier: transmission.localeIdentifier)
    guard compacted != transmission.text else { return transmission }
    return Transmission(
      id: transmission.id,
      startedAt: transmission.startedAt,
      endedAt: transmission.endedAt,
      text: compacted,
      segments: transmission.segments,
      classification: transmission.classification,
      localeIdentifier: transmission.localeIdentifier
    )
  }

  private func maybeShowNoAnchorHint(for transmission: Transmission) {
    guard case .displayed(.noAnchorConfigured) = transmission.classification,
      voiceFilter?.callSign == nil,
      !hasShownNoAnchorHint
    else {
      return
    }
    hasShownNoAnchorHint = true
    noAnchorHintStorage.saveHasShownNoAnchorHint(true)
    oneTimeNoAnchorHintVisible = true
  }

  private var displayableSegments: [TranscriptSegment] {
    guard !suppressedSegmentIDs.isEmpty else { return segments }
    return segments.filter { !suppressedSegmentIDs.contains($0.id) }
  }

  private func applyVoiceFilter(to segment: TranscriptSegment, speaker: SpeakerMatchDecision?) {
    guard let pipeline = voiceFilter, pipeline.enabled else { return }
    // Phase 2 (ADR 0007): use the REAL FluidAudio speaker classification of the audio that
    // produced this segment when available; fall back to `.nonPilot` (fail-open: show) when
    // no voice pack/profile is active so the call-sign-relevance gate alone decides — never
    // suppress on missing speaker info.
    let decision = pipeline.decide(
      text: segment.text,
      speaker: speaker ?? .nonPilot(bestPilotScore: 0),
      timestamp: segment.startedAt,
      // why: match the configured call sign in the SEGMENT's recognition language, so a French
      // clearance ("November un deux trois Alpha Bravo") decodes the French digits at the gate —
      // not only at the card classifier. Empty/English locale keeps the English decode (unchanged).
      localeIdentifier: segment.sourceLanguageCode
    )
    if case .suppress = decision.relevance {
      suppressedSegmentIDs.insert(segment.id)
    }
  }

  private func clearDerivedState(for id: UUID) {
    suppressedSegmentIDs.remove(id)
    translations[id] = nil
    translationTasks[id]?.cancel()
    translationTasks[id] = nil
    translationTaskTokens[id] = nil
    segmentOwner[id] = nil
  }

  private func startObservingEvents() {
    let stream = engine.events()
    eventTask = Task { @MainActor [weak self] in
      for await event in stream {
        guard let self else { return }
        switch event {
        case .partial(let text):
          self.partialText = text
          self.processTransmissionInput(.partial(text: text, at: self.now()))
        case .segment(let segment, let speaker):
          self.handleFinalSegment(segment, speaker: speaker)
          self.partialText = ""
        case .taskRestart:
          // why: the engine has already committed the live partial as an interim
          // segment; clearing here prevents the stale partial from lingering until
          // the next task's first partial arrives.
          self.processTransmissionInput(.taskRestart(at: self.now()))
          self.partialText = ""
        case .status(let newStatus):
          let oldStatus = self.status
          self.status = newStatus
          if oldStatus != .listening, newStatus == .listening {
            self.transmissionAssembler = self.makeTransmissionAssembler()
            self.beginPersistenceSessionIfNeeded()
            self.startTransmissionTickLoop()
          }
          if newStatus == .stopped {
            self.finishTransmissionAssembly(at: self.now())
            self.stopTransmissionTickLoop()
            self.partialText = ""
            self.endPersistenceSessionIfNeeded()
          }
          if case .failed = newStatus {
            self.finishTransmissionAssembly(at: self.now())
            self.stopTransmissionTickLoop()
            self.endPersistenceSessionIfNeeded()
          }
        }
      }
    }
  }

  private func startTransmissionTickLoop() {
    transmissionTickTask?.cancel()
    transmissionTickTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        try? await Task.sleep(nanoseconds: self.transmissionTickNanoseconds)
        guard !Task.isCancelled else { return }
        guard var assembler = self.transmissionAssembler else { continue }
        let updates = assembler.tick(now: self.now())
        self.transmissionAssembler = assembler
        self.applyTransmissionUpdates(updates)
      }
    }
  }

  private func stopTransmissionTickLoop() {
    transmissionTickTask?.cancel()
    transmissionTickTask = nil
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
      mostRecentTranscriptSessionID = session.id
    } catch {
      persistenceUnavailableForCurrentSession = true
      recordPersistenceFailure()
    }
  }

  private func persist(segment: TranscriptSegment, fallbackSessionID: UUID? = nil) {
    guard segment.source == .liveATC, let transcriptStore else { return }
    if activeTranscriptSessionID == nil, status == .listening {
      beginPersistenceSessionIfNeeded()
    }
    guard let sessionID = activeTranscriptSessionID ?? fallbackSessionID else { return }
    do {
      try transcriptStore.append(segment, to: sessionID)
    } catch {
      recordPersistenceFailure()
    }
  }

  private func persist(transmissionUpdate update: TransmissionUpdate) {
    let transmission = update.transmission
    guard !transmission.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let transcriptStore
    else {
      return
    }
    if activeTranscriptSessionID == nil, status == .listening {
      beginPersistenceSessionIfNeeded()
    }
    guard let sessionID = activeTranscriptSessionID else { return }
    do {
      switch update {
      case .opened, .updated:
        try transcriptStore.updateOpen(transmission, in: sessionID)
      case .closed:
        try transcriptStore.append(transmission, to: sessionID)
      }
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
      filteredTransmissions = [
        Transmission(
          id: segment.id,
          startedAt: segment.startedAt,
          endedAt: segment.startedAt,
          text: segment.text,
          segments: [segment],
          classification: .filtered(.addressedToOther),
          localeIdentifier: "en-US"
        )
      ]
      suppressedSegmentIDs = [segment.id]
      // why: in-memory only — persisting the flag from a UI-test seed would leak
      // first-run state across UI tests and make them order-dependent.
      hasEverStarted = true
    }
  #endif
}
