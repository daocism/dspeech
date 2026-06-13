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
  // why: emitted at every recognition-task boundary (benign restart, config rebuild,
  // availability blip) so the assembler can distinguish a task recycle from silence
  // and apply overlap-merge to the replayed audio's re-transcription.
  case taskRestart
  case status(LiveTranscriptionStatus)
}

@MainActor
protocol LiveTranscriptionEngine: AnyObject {
  var status: LiveTranscriptionStatus { get }
  func events() -> AsyncStream<LiveTranscriptionEvent>
  func start() async
  func stop()
}

#if DEBUG
  @MainActor
  final class ScriptedLiveTranscriptionEngine: LiveTranscriptionEngine {
    enum Step: Sendable {
      case partial(String)
      case segment(String, confidence: Double, sourceLanguageCode: String)
      case status(LiveTranscriptionStatus)
    }

    static let launchArgument = "-dspeech.uitest.scripted-engine"

    private static let defaultScript: [Step] = [
      .partial("Tower N123AB"),
      .segment(
        "Tower N123AB cleared for takeoff",
        confidence: 0.96,
        sourceLanguageCode: "en"
      ),
    ]

    private let script: [Step]
    private var continuation: AsyncStream<LiveTranscriptionEvent>.Continuation?
    private(set) var status: LiveTranscriptionStatus = .idle

    init(script: [Step] = defaultScript) {
      self.script = script
    }

    static func makeFromLaunchArguments(
      _ arguments: [String] = CommandLine.arguments
    ) -> ScriptedLiveTranscriptionEngine? {
      guard arguments.contains(launchArgument) else { return nil }
      return ScriptedLiveTranscriptionEngine()
    }

    func events() -> AsyncStream<LiveTranscriptionEvent> {
      AsyncStream<LiveTranscriptionEvent> { continuation in
        self.continuation = continuation
        continuation.yield(.status(self.status))
      }
    }

    func start() async {
      transition(to: .requestingPermission)
      transition(to: .listening)
      for step in script {
        switch step {
        case .partial(let text):
          continuation?.yield(.partial(text))
        case .segment(let text, let confidence, let sourceLanguageCode):
          continuation?.yield(
            .segment(
              TranscriptSegment(
                text: text,
                confidence: confidence,
                sourceLanguageCode: sourceLanguageCode,
                source: .liveATC
              )))
        case .status(let status):
          transition(to: status)
        }
      }
      if status == .requestingPermission || status == .ready || status == .listening {
        transition(to: .stopped)
      }
    }

    func stop() {
      transition(to: .stopped)
    }

    private func transition(to newStatus: LiveTranscriptionStatus) {
      status = newStatus
      continuation?.yield(.status(newStatus))
    }
  }
#endif

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
