@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech
import Testing

@testable import Dspeech

// why: this suite exercises the REAL Apple on-device Speech stack — the F1 capability
// that physically cannot run in the iOS Simulator and was therefore never actually
// verified before shipping. It is the regression guard for the "tap mic → flashes to
// listening → dies in ~1 s with no message" defect. Run it on a physical device:
//   xcodebuild test -project Dspeech.xcodeproj -scheme Dspeech \
//     -destination 'platform=iOS,id=<UDID>' -only-testing:DspeechTests/OnDeviceSpeechRecognitionTests
// The host-app test process inherits the app's microphone/speech TCC grant, so no
// permission dialog appears once the app has been authorized once.
@MainActor
struct OnDeviceSpeechRecognitionTests {

  private static var isSimulator: Bool {
    #if targetEnvironment(simulator)
      return true
    #else
      return false
    #endif
  }

  // The locales the live engine can be pointed at via RecognitionSettings.
  private static let candidateLocales = ["en-US", Locale.current.identifier]

  @Test
  func recognizerReportsOnDeviceSupportForActiveLocale() {
    guard !Self.isSimulator else { return }  // device-only; the Simulator has no on-device model
    for identifier in Set(Self.candidateLocales) {
      let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier))
      let available = recognizer?.isAvailable ?? false
      let onDevice = recognizer?.supportsOnDeviceRecognition ?? false
      // Surfaced into the test log so a failure tells us EXACTLY which locale lacks the
      // on-device asset, instead of a silent runtime stop.
      let report =
        "locale=\(identifier) recognizerExists=\(recognizer != nil) isAvailable=\(available) supportsOnDeviceRecognition=\(onDevice) authStatus=\(Self.authName)"
      Issue.record(Comment(rawValue: report))
      #expect(recognizer != nil, "no SFSpeechRecognizer for \(identifier)")
      #expect(available, "recognizer not available for \(identifier)")
      #expect(onDevice, "on-device recognition unsupported for \(identifier)")
    }
  }

  @Test
  func onDeviceRecognitionTranscribesSynthesizedSpeech() async throws {
    guard !Self.isSimulator else { return }
    guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
      Issue.record("speech not authorized (status=\(Self.authName)); grant once on-device, rerun")
      return
    }
    let recognizer = try #require(SFSpeechRecognizer(locale: Locale(identifier: "en-US")))

    let buffers = await Self.synthesize("november one two three five", language: "en-US")
    #expect(!buffers.isEmpty, "speech synthesis produced no audio buffers")

    let outcome = await Self.recognizeOnDevice(buffers, recognizer: recognizer)
    switch outcome {
    case .transcript(let text):
      Issue.record("on-device transcript: \(text)")
      #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    case .failure(let domain, let code, let description):
      // why: capture the EXACT NSError domain/code so the root cause is unambiguous in
      // the test report rather than swallowed at runtime.
      Issue.record("on-device recognition FAILED domain=\(domain) code=\(code) desc=\(description)")
      #expect(Bool(false), "on-device recognition errored: \(domain) \(code)")
    }
  }

  // Regression guard for the reported F1 defect: the live engine must SUSTAIN a
  // listening session across the first beat of silence instead of finalizing the one
  // recognition task and silently dropping to .stopped within ~1 s. Needs the real mic
  // + on-device Speech, so device-only. No acoustic input required — ambient silence is
  // exactly the input that used to kill the session.
  @Test
  func liveEngineSustainsListeningThroughSilenceOnDevice() async throws {
    guard !Self.isSimulator else { return }
    guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
      Issue.record("speech not authorized (status=\(Self.authName)); grant once on-device, rerun")
      return
    }
    let engine = AppleSpeechLiveTranscriptionEngine(localeProvider: { "en-US" })
    let trail = StatusTrail()
    let observer = Task { @MainActor in
      for await event in engine.events() {
        if case .status(let status) = event { trail.append(status) }
      }
    }
    await engine.start()
    try await Task.sleep(nanoseconds: 4_000_000_000)
    let terminal = engine.status
    engine.stop()
    observer.cancel()
    Issue.record("status trail: \(trail.joined()) | terminal=\(terminal)")
    #expect(
      terminal == .listening,
      "engine failed to sustain listening through 4 s of silence; ended at \(terminal)")
  }

  // MARK: - helpers

  private static var authName: String {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .notDetermined: "notDetermined"
    case .denied: "denied"
    case .restricted: "restricted"
    case .authorized: "authorized"
    @unknown default: "unknown"
    }
  }

  private enum RecognitionOutcome: Sendable {
    case transcript(String)
    case failure(domain: String, code: Int, description: String)
  }

  @MainActor
  private static func synthesize(_ text: String, language: String) async -> [AVAudioPCMBuffer] {
    let holder = SynthesisHolder()
    let box: Unchecked<[AVAudioPCMBuffer]> = await withCheckedContinuation { continuation in
      holder.begin(text: text, language: language, continuation: continuation)
    }
    return box.value
  }

  @MainActor
  private static func recognizeOnDevice(
    _ buffers: [AVAudioPCMBuffer],
    recognizer: SFSpeechRecognizer
  ) async -> RecognitionOutcome {
    await withCheckedContinuation {
      (continuation: CheckedContinuation<RecognitionOutcome, Never>) in
      let request = SFSpeechAudioBufferRecognitionRequest()
      request.requiresOnDeviceRecognition = true
      request.shouldReportPartialResults = false
      request.taskHint = .dictation
      let completion = OneShot<RecognitionOutcome>(continuation)
      let task = recognizer.recognitionTask(with: request) { result, error in
        if let error = error as NSError? {
          completion.finish(
            .failure(
              domain: error.domain, code: error.code, description: error.localizedDescription))
          return
        }
        if let result, result.isFinal {
          completion.finish(.transcript(result.bestTranscription.formattedString))
        }
      }
      for buffer in buffers where buffer.frameLength > 0 {
        request.append(buffer)
      }
      request.endAudio()
      _ = task
    }
  }
}

@MainActor
private final class StatusTrail {
  private var statuses: [LiveTranscriptionStatus] = []
  func append(_ status: LiveTranscriptionStatus) { statuses.append(status) }
  func joined() -> String { statuses.map { "\($0)" }.joined(separator: " -> ") }
}

// why: AVSpeechSynthesizer.write streams buffers on an internal queue and signals
// completion with a final zero-length buffer; the synthesizer must outlive the stream.
private final class SynthesisHolder: @unchecked Sendable {
  private let synth = AVSpeechSynthesizer()
  private let lock = NSLock()
  private var buffers: [AVAudioPCMBuffer] = []
  private var finished = false
  private var continuation: CheckedContinuation<Unchecked<[AVAudioPCMBuffer]>, Never>?

  func begin(
    text: String,
    language: String,
    continuation: CheckedContinuation<Unchecked<[AVAudioPCMBuffer]>, Never>
  ) {
    self.continuation = continuation
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: language)
    synth.write(utterance) { [weak self] buffer in
      guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
      if pcm.frameLength == 0 {
        self.complete()
      } else if let copy = pcm.dspeechDeepCopy() {
        self.lock.withLock { self.buffers.append(copy) }
      }
    }
  }

  private func complete() {
    let toResume: CheckedContinuation<Unchecked<[AVAudioPCMBuffer]>, Never>?
    let payload: [AVAudioPCMBuffer]
    (toResume, payload) = lock.withLock {
      guard !finished else { return (nil, []) }
      finished = true
      let c = continuation
      continuation = nil
      return (c, buffers)
    }
    toResume?.resume(returning: Unchecked(value: payload))
  }
}

// why: AVAudioPCMBuffer is not Sendable; this box hands a fully-owned, no-longer-mutated
// buffer batch across the continuation boundary without weakening real concurrency safety.
private struct Unchecked<T>: @unchecked Sendable {
  let value: T
}

private final class OneShot<Payload: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  private let continuation: CheckedContinuation<Payload, Never>

  init(_ continuation: CheckedContinuation<Payload, Never>) {
    self.continuation = continuation
  }

  func finish(_ payload: Payload) {
    let shouldResume = lock.withLock {
      guard !done else { return false }
      done = true
      return true
    }
    if shouldResume { continuation.resume(returning: payload) }
  }
}
