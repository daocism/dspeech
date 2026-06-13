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
  // why: the speaker decision is the REAL FluidAudio classification of the audio that
  // produced this segment (nil when no voice pack / no gate). It rides the event rather
  // than TranscriptSegment so the persisted transcript model stays unchanged; the view
  // model feeds it into the voice-filter gate to suppress the operator's own read-backs.
  case segment(TranscriptSegment, speaker: SpeakerMatchDecision?)
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
              ), speaker: nil))
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

// why: carries BOTH the pre-ASR routing decision and the speaker classification of the
// buffer. The engine keeps the speaker to stamp onto the resulting segment so the post-ASR
// voice-filter gate can suppress the operator's own read-backs (ADR 0007 phase 2).
struct GatedAudioRouting: Sendable {
  let routing: PreTranscriptionRoutingDecision
  let speaker: SpeakerMatchDecision?
}

@MainActor
protocol SpeechAudioBufferGate: AnyObject {
  func route(samples: [Float], sampleRate: Double) async throws -> GatedAudioRouting
}

@MainActor
final class AlwaysTranscribeSpeechAudioBufferGate: SpeechAudioBufferGate {
  func route(samples: [Float], sampleRate: Double) async throws -> GatedAudioRouting {
    GatedAudioRouting(routing: .transcribe(reason: .filterDisabled), speaker: nil)
  }
}

@MainActor
final class VoiceFilterSpeechAudioBufferGate: SpeechAudioBufferGate {
  private let pipeline: VoiceFilterPipeline

  init(pipeline: VoiceFilterPipeline) {
    self.pipeline = pipeline
  }

  func route(samples: [Float], sampleRate: Double) async throws -> GatedAudioRouting {
    let speaker: SpeakerMatchDecision
    do {
      speaker = try await pipeline.classify(samples: samples, sampleRate: sampleRate)
    } catch {
      // why: fail open — a thrown classifier (absent/disabled pack, unavailable
      // identifier, capture failure) must never silently drop ATC audio before ASR.
      return GatedAudioRouting(routing: .transcribe(reason: .classifierUnavailable), speaker: nil)
    }
    return GatedAudioRouting(
      routing: pipeline.routeBeforeTranscription(speaker: speaker), speaker: speaker)
  }
}
