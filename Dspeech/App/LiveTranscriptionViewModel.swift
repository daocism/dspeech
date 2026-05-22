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

    private let engine: any LiveTranscriptionEngine
    private let voiceFilter: VoiceFilterPipeline?
    private var eventTask: Task<Void, Never>?

    init(engine: any LiveTranscriptionEngine, voiceFilter: VoiceFilterPipeline? = nil) {
        self.engine = engine
        self.voiceFilter = voiceFilter
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
        if case let .failed(message) = status { return message }
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
    }

    private func append(segment: TranscriptSegment) {
        segments.append(segment)
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
