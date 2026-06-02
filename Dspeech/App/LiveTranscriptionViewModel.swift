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
  private(set) var translationUnavailable = false

  private let engine: any LiveTranscriptionEngine
  private let voiceFilter: VoiceFilterPipeline?
  private let translator: (any TranslationService)?
  private let translationTarget: @MainActor () -> Locale.Language?
  private var eventTask: Task<Void, Never>?
  private var translationTasks: [UUID: Task<Void, Never>] = [:]

  init(
    engine: any LiveTranscriptionEngine,
    voiceFilter: VoiceFilterPipeline? = nil,
    translator: (any TranslationService)? = nil,
    translationTarget: @escaping @MainActor () -> Locale.Language? = { nil }
  ) {
    self.engine = engine
    self.voiceFilter = voiceFilter
    self.translator = translator
    self.translationTarget = translationTarget
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

  var lastErrorMessage: String? {
    if case .failed(let message) = status { return message }
    return nil
  }

  func start() async {
    if eventTask == nil {
      startObservingEvents()
    }
    await engine.start()
  }

  func stop() {
    engine.stop()
  }

  func reset() {
    segments.removeAll()
    partialText = ""
    filterIndicators.removeAll()
    suppressedSegmentIDs.removeAll()
    clearTranslations()
  }

  func clearTranslations() {
    for task in translationTasks.values { task.cancel() }
    translationTasks.removeAll()
    translations.removeAll()
    translationUnavailable = false
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
    translationTasks[id] = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.translationTasks[id] = nil }
      do {
        let result = try await translator.translate(text, from: source, into: target)
        guard !Task.isCancelled else { return }
        self.translations[id] = result
        self.translationUnavailable = false
      } catch TranslationServiceError.languagePackNotInstalled {
        self.translationUnavailable = true
      } catch {
        // why: translation is best-effort and never blocks the transcript; other
        // failures simply leave the segment un-glossed.
      }
    }
  }

  private func append(segment: TranscriptSegment) {
    segments.append(segment)
    maybeTranslate(segment)
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
          self.status = newStatus
          if newStatus == .stopped { self.partialText = "" }
        }
      }
    }
  }
}
