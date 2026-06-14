@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

extension AppleSpeechLiveTranscriptionEngine {
  // why: the segmenter cuts a decision window at a trailing-silence utterance edge
  // (>= minSilence after >= minSpeech of speech) or, failing that, at this
  // conservative max-window cap — keeping the prior 1.0 s ceiling as a strict upper
  // bound so this change is never a latency regression; sub-window tails fail open.
  static let decisionWindowSeconds = 1.0
  static let minSpeechSeconds = 0.25
  static let minSilenceSeconds = 0.40

  var isStartupOrListening: Bool {
    status == .requestingPermission || status == .listening
  }

  // why: the restart-vs-surface decision is the most important business logic in the engine
  // (the F1 silent-failure fix). Extracted as a pure, synchronous function so it is unit-tested
  // directly with synthesized failures — the live recognitionTask callback that produces those
  // failures can't be driven deterministically in a test.
  static func terminationDecision(
    isListening: Bool,
    hasRecognizer: Bool,
    failure: ASRFailure?
  ) -> RecognitionTerminationDecision {
    guard isListening, hasRecognizer else { return .ignore }
    if let failure, !failure.isBenignRestart {
      return .fail("asr-error: \(failure.domain)#\(failure.code) \(failure.message)")
    }
    return .restart
  }

  // why: the restart-loop death-spiral ceiling resets when the recognizer proves it is ALIVE — ANY
  // clean final, including an empty/whitespace one it retracts after silence, not only a non-empty
  // segment. A loud cockpit produces empty finals from noise-triggered boundary cuts; counting those
  // toward the 5-restarts/10s ceiling would FALSELY kill the engine mid-flight. Partials and failures
  // still count, so a genuine restart loop (init failures produce failures, never clean finals) is
  // still caught. Pure helper so the inline-callback decision is unit-tested directly.
  static func shouldResetRestartGuard(isFinal: Bool, failure: ASRFailure?) -> Bool {
    isFinal && failure == nil
  }

  static func startupGateDecision(
    firstRead: RecognizerCapabilityRead,
    secondRead: RecognizerCapabilityRead?,
    requireOnDeviceModel: Bool,
    skipPermissionRequests: Bool
  ) -> RecognizerStartupGateDecision {
    let read =
      firstRead.isReady(
        requireOnDeviceModel: requireOnDeviceModel,
        skipPermissionRequests: skipPermissionRequests
      ) ? firstRead : secondRead ?? firstRead
    if !skipPermissionRequests, !read.isAvailable {
      return .fail("recognizer-unavailable")
    }
    if requireOnDeviceModel, !read.supportsOnDeviceRecognition {
      return .fail("on-device-model-missing")
    }
    return .ready
  }

  static func sourceLanguageCode(for localeIdentifier: String) -> String {
    Locale(identifier: localeIdentifier).language.languageCode?.identifier ?? localeIdentifier
  }

  static func interimRestartSegment(text: String, localeIdentifier: String) -> TranscriptSegment {
    TranscriptSegment(
      text: text,
      confidence: 0,
      sourceLanguageCode: Self.sourceLanguageCode(for: localeIdentifier),
      source: .liveATC,
      isInterimRestartCommit: true
    )
  }

  static func restartDecision(
    isListening: Bool,
    isAudioEngineRunning: Bool
  ) -> RecognitionRestartDecision {
    guard isListening else { return .ignore }
    guard isAudioEngineRunning else { return .fail("engine-died-before-restart") }
    return .restart
  }

  nonisolated static func monoFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
    LiveAudioCaptureConduit.monoFloatSamples(from: buffer)
  }

  nonisolated static func averageConfidence(for transcription: SFTranscription) -> Double {
    let segments = transcription.segments
    guard !segments.isEmpty else { return 0.0 }
    let total = segments.reduce(0.0) { $0 + Double($1.confidence) }
    return total / Double(segments.count)
  }

  nonisolated static func requestSpeechAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }

  nonisolated static func requestMicrophonePermission() async -> Bool {
    await AVAudioApplication.requestRecordPermission()
  }
}

struct PendingRecognitionPartial: Sendable {
  private var text = ""

  mutating func record(event: LiveTranscriptionEvent?, isFinal: Bool) {
    if case .partial(let partialText) = event {
      text = partialText
    }
    // why: clear ONLY when the final actually produced a committed segment. An EMPTY final
    // (recognizer ended with no text — common when it retracts a faint utterance right after a long
    // silence) must NOT discard the last shown partial; keeping it lets the boundary restart commit
    // it as a card instead of the live line dictating then silently vanishing (2026-06-14 device).
    if isFinal, case .segment = event {
      clear()
    }
  }

  mutating func takeTrimmedText() -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    clear()
    return trimmed.isEmpty ? nil : trimmed
  }

  mutating func clear() {
    text = ""
  }
}

// why: the outcome of a recognition-task termination. `restart` keeps the mic+tap live and
// recycles the recognition request (normal final or a benign no-speech timeout); `fail` surfaces
// a real recognition fault; `ignore` is for callbacks that arrive when the session is no longer
// listening. Made a first-class type so the decision is testable in isolation.
enum RecognitionTerminationDecision: Equatable, Sendable {
  case ignore
  case restart
  case fail(String)
}

enum RecognitionRestartDecision: Equatable, Sendable {
  case ignore
  case restart
  case fail(String)
}

struct RecognizerCapabilityRead: Equatable, Sendable {
  let isAvailable: Bool
  let supportsOnDeviceRecognition: Bool

  func isReady(requireOnDeviceModel: Bool, skipPermissionRequests: Bool) -> Bool {
    (skipPermissionRequests || isAvailable)
      && (!requireOnDeviceModel || supportsOnDeviceRecognition)
  }
}

enum RecognizerStartupGateDecision: Equatable, Sendable {
  case ready
  case fail(String)
}

enum ASRRestartLoopDecision: Equatable, Sendable {
  case allow
  case fail(String)
}

struct ASRRestartLoopGuard: Sendable {
  let maxRestartCount: Int
  let window: Duration
  private var restartInstants: [ContinuousClock.Instant] = []

  init(maxRestartCount: Int, window: Duration) {
    self.maxRestartCount = maxRestartCount
    self.window = window
  }

  mutating func recordResult() {
    restartInstants.removeAll()
  }

  mutating func recordRestart(now: ContinuousClock.Instant) -> ASRRestartLoopDecision {
    restartInstants = restartInstants.filter { $0.duration(to: now) <= window }
    restartInstants.append(now)
    if restartInstants.count > maxRestartCount {
      return .fail("asr-restart-loop")
    }
    return .allow
  }
}

struct AudioReplayTail<Buffer> {
  private struct Entry {
    let buffer: Buffer
    let durationSeconds: Double
  }

  private let maxDurationSeconds: Double
  private let maxBufferCount: Int
  private var entries: [Entry] = []

  init(maxDurationSeconds: Double, maxBufferCount: Int) {
    self.maxDurationSeconds = max(0, maxDurationSeconds)
    self.maxBufferCount = max(0, maxBufferCount)
  }

  var buffers: [Buffer] {
    entries.map(\.buffer)
  }

  mutating func append(_ buffer: Buffer, sampleCount: Int, sampleRate: Double) {
    guard sampleCount > 0, sampleRate > 0, maxBufferCount > 0, maxDurationSeconds > 0 else {
      return
    }
    entries.append(Entry(buffer: buffer, durationSeconds: Double(sampleCount) / sampleRate))
    trim()
  }

  mutating func removeAll() {
    entries.removeAll()
  }

  private mutating func trim() {
    while entries.count > maxBufferCount {
      entries.removeFirst()
    }
    while totalDurationSeconds > maxDurationSeconds, !entries.isEmpty {
      entries.removeFirst()
    }
  }

  private var totalDurationSeconds: Double {
    entries.reduce(0) { $0 + $1.durationSeconds }
  }
}

struct RecognitionCallbackEvent: Sendable {
  let generation: Int
  let event: LiveTranscriptionEvent?
  let isFinal: Bool
  let failure: ASRFailure?
}

struct ASRFailure: Equatable, Sendable {
  let domain: String
  let code: Int
  let message: String

  // why: these terminations mean the current Apple Speech request ended, not that live capture
  // is dead. Restart the request, but the engine-level restart-loop guard still fails loudly if
  // they repeat without any recognized result.
  var isBenignRestart: Bool {
    if domain == "kAFAssistantErrorDomain", code == 1110 { return true }
    if domain == "kAFAssistantErrorDomain", code == 203 {
      return message.localizedCaseInsensitiveContains("retry")
    }
    if domain == "SFSpeechErrorDomain" {
      let lowercased = message.lowercased()
      return lowercased.contains("duration limit")
        || lowercased.contains("request timed out")
        || lowercased.contains("request-timeout")
        || lowercased.contains("timed out")
    }
    return false
  }
}

final class LiveRecognizerAvailabilityDelegate: NSObject, SFSpeechRecognizerDelegate {
  weak var engine: AppleSpeechLiveTranscriptionEngine?

  init(engine: AppleSpeechLiveTranscriptionEngine) {
    self.engine = engine
  }

  nonisolated func speechRecognizer(
    _ speechRecognizer: SFSpeechRecognizer,
    availabilityDidChange available: Bool
  ) {
    Task { @MainActor [weak engine] in
      engine?.handleRecognizerAvailabilityChange(isAvailable: available)
    }
  }
}

@MainActor
protocol LiveSpeechAuthorizing {
  func requestSpeechAuthorization() async -> Bool
  func requestMicrophonePermission() async -> Bool
}

@MainActor
struct AppleLiveSpeechAuthorizer: LiveSpeechAuthorizing {
  func requestSpeechAuthorization() async -> Bool {
    await AppleSpeechLiveTranscriptionEngine.requestSpeechAuthorization()
  }

  func requestMicrophonePermission() async -> Bool {
    await AppleSpeechLiveTranscriptionEngine.requestMicrophonePermission()
  }
}
