import Foundation

enum LiveTranscriptionStatus: Equatable, Sendable {
    case idle
    case requestingPermission
    case ready
    case listening
    case stopped
    case failed(String)
}

enum LiveTranscriptionEvent: Sendable {
    case partial(String)
    case segment(TranscriptSegment)
    case status(LiveTranscriptionStatus)
}

@MainActor
protocol LiveTranscriptionEngine: AnyObject {
    var status: LiveTranscriptionStatus { get }
    func events() -> AsyncStream<LiveTranscriptionEvent>
    func start() async
    func stop()
}

@MainActor
protocol SpeechAudioBufferGate: AnyObject {
    func route(samples: [Float], sampleRate: Double) async throws -> PreTranscriptionRoutingDecision
}

@MainActor
final class AlwaysTranscribeSpeechAudioBufferGate: SpeechAudioBufferGate {
    func route(samples: [Float], sampleRate: Double) async throws -> PreTranscriptionRoutingDecision {
        .transcribe(reason: .filterDisabled)
    }
}

@MainActor
final class VoiceFilterSpeechAudioBufferGate: SpeechAudioBufferGate {
    private let pipeline: VoiceFilterPipeline

    init(pipeline: VoiceFilterPipeline) {
        self.pipeline = pipeline
    }

    func route(samples: [Float], sampleRate: Double) async throws -> PreTranscriptionRoutingDecision {
        let speaker: SpeakerMatchDecision
        do {
            speaker = try await pipeline.classify(samples: samples, sampleRate: sampleRate)
        } catch {
            // why: fail open — a thrown classifier (absent/disabled pack, unavailable
            // identifier, capture failure) must never silently drop ATC audio before ASR.
            return .transcribe(reason: .classifierUnavailable)
        }
        return pipeline.routeBeforeTranscription(speaker: speaker)
    }
}

enum AudioBufferRouting: Equatable, Sendable {
    case transcribe
    case discard
}

@MainActor
final class SerialAudioRoutingQueue<Element: Sendable> {
    private nonisolated let continuation: AsyncStream<Element>.Continuation
    private var consumer: Task<Void, Never>?

    init(
        route: @escaping @Sendable @MainActor (Element) async -> AudioBufferRouting,
        append: @escaping @Sendable @MainActor (Element) -> Void
    ) {
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        self.continuation = continuation
        // why: a single sequential consumer is the serialization boundary — buffer N+1 is
        // not routed until buffer N's transcribe/discard decision and any append have
        // completed, so capture order is preserved even when classification latency varies.
        self.consumer = Task { @MainActor in
            for await element in stream {
                if case .transcribe = await route(element) {
                    append(element)
                }
            }
        }
    }

    nonisolated func submit(_ element: Element) {
        continuation.yield(element)
    }

    func finish() {
        continuation.finish()
        consumer?.cancel()
        consumer = nil
    }
}
