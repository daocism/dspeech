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
