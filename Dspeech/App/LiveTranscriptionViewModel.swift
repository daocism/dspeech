import Foundation
import Observation

@MainActor
@Observable
final class LiveTranscriptionViewModel {
    private(set) var segments: [TranscriptSegment] = []
    private(set) var partialText: String = ""
    private(set) var status: LiveTranscriptionStatus = .idle

    private let engine: any LiveTranscriptionEngine
    private var eventTask: Task<Void, Never>?

    init(engine: any LiveTranscriptionEngine) {
        self.engine = engine
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
                    self.segments.append(segment)
                    self.partialText = ""
                case .status(let newStatus):
                    self.status = newStatus
                    if newStatus == .stopped { self.partialText = "" }
                }
            }
        }
    }
}
