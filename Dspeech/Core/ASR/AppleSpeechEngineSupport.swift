@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

extension AppleSpeechLiveTranscriptionEngine {
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

  static func restartDecision(
    isListening: Bool,
    isAudioEngineRunning: Bool
  ) -> RecognitionRestartDecision {
    guard isListening else { return .ignore }
    guard isAudioEngineRunning else { return .fail("engine-died-before-restart") }
    return .restart
  }

  nonisolated static func monoFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
    guard buffer.format.commonFormat == .pcmFormatFloat32,
      let channelData = buffer.floatChannelData
    else {
      return nil
    }
    let frameLength = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard frameLength > 0, channelCount > 0 else { return nil }

    if channelCount == 1 {
      return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }

    var mono = [Float](repeating: 0, count: frameLength)
    let scale = 1.0 / Float(channelCount)
    if buffer.format.isInterleaved {
      // why: interleaved multichannel lives in a single pointer as L,R,L,R…; index
      // by frame*channelCount + channel, not per-channel pointers (which would be
      // out of bounds for interleaved external-interface input).
      let pointer = channelData[0]
      for frame in 0..<frameLength {
        var sum: Float = 0
        for channel in 0..<channelCount {
          sum += pointer[frame * channelCount + channel]
        }
        mono[frame] = sum * scale
      }
    } else {
      for channel in 0..<channelCount {
        let pointer = channelData[channel]
        for frame in 0..<frameLength {
          mono[frame] += pointer[frame]
        }
      }
      for frame in 0..<frameLength {
        mono[frame] *= scale
      }
    }
    return mono
  }
}

extension AVAudioPCMBuffer {
  // why: AVAudioEngine reuses the tap's buffer storage across callbacks, so any
  // buffer handed to async work must be deep-copied synchronously inside the tap or
  // its samples are overwritten before they are read.
  func dspeechDeepCopy() -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
      return nil
    }
    copy.frameLength = frameLength
    let frames = Int(frameLength)
    let channels = Int(format.channelCount)
    guard frames > 0, channels > 0 else { return copy }
    // why: interleaved buffers expose ONE channel pointer holding frames*channels
    // samples (L,R,L,R…); deinterleaved expose `channels` pointers of `frames` each.
    // Indexing per-channel on an interleaved buffer reads out of bounds and copies
    // only half the audio — silent corruption on external USB / line-in routes.
    let pointerCount = format.isInterleaved ? 1 : channels
    let elementsPerPointer = format.isInterleaved ? frames * channels : frames
    if let source = floatChannelData, let destination = copy.floatChannelData {
      for index in 0..<pointerCount {
        destination[index].update(from: source[index], count: elementsPerPointer)
      }
    } else if let source = int16ChannelData, let destination = copy.int16ChannelData {
      for index in 0..<pointerCount {
        destination[index].update(from: source[index], count: elementsPerPointer)
      }
    } else if let source = int32ChannelData, let destination = copy.int32ChannelData {
      for index in 0..<pointerCount {
        destination[index].update(from: source[index], count: elementsPerPointer)
      }
    } else {
      return nil
    }
    return copy
  }
}

struct LiveEngineCleanupResult {
  let deactivationFailureSlug: String?
}

enum LiveEngineError: LocalizedError {
  case invalidInputFormat
  case capturePipelineUnavailable
  case audioEngineNotRunningAfterConfigurationChange

  var errorDescription: String? {
    switch self {
    case .invalidInputFormat:
      return "invalid-input-format"
    case .capturePipelineUnavailable:
      return "capture-pipeline-unavailable"
    case .audioEngineNotRunningAfterConfigurationChange:
      return "audio-engine-not-running-after-configuration-change"
    }
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
  let hasResult: Bool
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

@MainActor
protocol LiveAudioSessionManaging: AnyObject {
  func configureForLiveRecording() throws
  func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

@MainActor
final class SystemLiveAudioSession: LiveAudioSessionManaging {
  private let session: AVAudioSession

  init(session: AVAudioSession = .sharedInstance()) {
    self.session = session
  }

  func configureForLiveRecording() throws {
    try LiveAudioSessionRouting.configureRecordCategory(session)
  }

  func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
    try session.setActive(active, options: options)
  }
}
