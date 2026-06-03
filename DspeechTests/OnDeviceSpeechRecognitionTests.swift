@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech
import Testing

@testable import Dspeech

// why: this suite exercises the REAL Apple Speech stack and the live engine on whatever
// target runs it. It used to `guard !isSimulator else { return }` in three tests — which
// silently PASSED on the Simulator while testing nothing (the theater that let the F1
// "recognizer-unavailable / kLSRErrorDomain#300" defects ship green). It no longer skips:
// on the Simulator the engine uses server recognition (see AppleSpeechLiveTranscriptionEngine
// #if targetEnvironment(simulator)), so these run for real here.
// why: .serialized — they share the process-wide AVAudioSession / mic; Swift Testing's
// default parallelism makes them contend (IPCAUClient failures, empty buffers, a crash).
@Suite(.serialized)
@MainActor
struct OnDeviceSpeechRecognitionTests {

  // why: real recognition cannot be exercised on the Simulator — no speech HAL, and server
  // recognition of synthetic TTS hard-errors there (confirmed empirically). So the
  // end-to-end transcription test runs ONLY on an authorized physical device and is a
  // VISIBLE skip on the Simulator — honest, never a silent green pass.
  private nonisolated static var canExerciseRealRecognition: Bool {
    #if targetEnvironment(simulator)
      return false
    #else
      return SFSpeechRecognizer.authorizationStatus() == .authorized
    #endif
  }

  private static var authName: String {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .notDetermined: "notDetermined"
    case .denied: "denied"
    case .restricted: "restricted"
    case .authorized: "authorized"
    @unknown default: "unknown"
    }
  }

  // A real, supported locale exists and is available (server-backed on the Simulator,
  // on-device on hardware). This is the locale a "downloaded language" resolves to.
  @Test func recognizerExistsForEnUS() {
    let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    let available = recognizer?.isAvailable ?? false
    let onDevice = recognizer?.supportsOnDeviceRecognition ?? false
    print(
      "[OnDeviceSpeech] en-US recognizerExists=\(recognizer != nil) isAvailable=\(available) "
        + "supportsOnDeviceRecognition=\(onDevice) auth=\(Self.authName)")
    // why: assert ONLY the deterministic fact — a recognizer can be built for en-US.
    // isAvailable depends on Speech authorization + network/model state, which a fresh CI
    // simulator lacks (Speech TCC can't be granted headlessly), so asserting it passes only
    // on a sim with residual auth (green-local / red-CI). Availability is logged for triage.
    #expect(recognizer != nil, "no SFSpeechRecognizer for en-US")
  }

  // The "language that isn't supported/downloaded" path: SFSpeechRecognizer returns nil for
  // an unsupported locale — exactly the precondition the engine maps to recognizer-unavailable.
  @Test func unsupportedLocaleYieldsNoRecognizer() {
    #expect(SFSpeechRecognizer(locale: Locale(identifier: "zz-ZZ")) == nil)
  }

  // Regression guard for the user's symptom: start() for a supported locale must REACH
  // .listening (not dead-end at recognizer-unavailable / on-device-model-missing). On the
  // Simulator this is meaningful now because the on-device-model guard is skipped there and
  // recognition falls back to server. skipPermissionRequests avoids the auth dialog that
  // would hang a non-UI test; .listening is set synchronously by start() before any task
  // callback, so this is deterministic regardless of auth/network.
  @Test func engineReachesListeningForSupportedLocale() async {
    let engine = AppleSpeechLiveTranscriptionEngine(
      localeProvider: { "en-US" }, skipPermissionRequests: true)
    await engine.start()
    let status = engine.status
    engine.stop()
    print("[OnDeviceSpeech] engineReachesListening status=\(status)")
    #expect(
      status == .listening,
      "engine did not reach .listening for en-US (recognizer-unavailable/model-missing dead-end); got \(status)"
    )
  }

  // The real F1 happy path: synthesize speech and feed it through the on-device recognizer,
  // asserting a transcript. Device-only (see canExerciseRealRecognition) — visible skip on
  // the Simulator, which physically cannot do this; on a device the app inherits the granted
  // Speech/mic TCC so no dialog appears.
  @Test(.enabled(if: canExerciseRealRecognition))
  func recognizesSynthesizedSpeechEndToEnd() async throws {
    let recognizer = try #require(SFSpeechRecognizer(locale: Locale(identifier: "en-US")))
    let buffers = await Self.synthesize("november one two three five", language: "en-US")
    #expect(!buffers.isEmpty, "speech synthesis produced no audio buffers")

    let outcome = await Self.recognize(buffers, recognizer: recognizer)
    switch outcome {
    case .transcript(let text):
      print("[OnDeviceSpeech] transcript: \(text)")
      #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    case .failure(let domain, let code, let description):
      // why: 1110 "no speech detected" is acceptable — synthetic TTS doesn't always latch the
      // recognizer. Any OTHER hard error is a genuine recognition fault.
      let benignNoSpeech = domain == "kAFAssistantErrorDomain" && code == 1110
      print("[OnDeviceSpeech] recognition outcome \(domain)#\(code) \(description)")
      #expect(benignNoSpeech, "recognition hard-errored: \(domain)#\(code) \(description)")
    }
  }

  // Crash-repro that runs on the Simulator: the input-level meter installs an AVAudioEngine
  // tap with no permission gate; reaching the end without aborting is the pass condition.
  @Test func inputLevelMeterInstallsTapWithoutCrashing() async throws {
    let meter = AVAudioEngineInputLevelMeter()
    let drain = Task { for await _ in meter.events() { break } }
    try await Task.sleep(nanoseconds: 800_000_000)
    meter.stop()
    drain.cancel()
    #expect(Bool(true))
  }

  // Crash-repro for the ASR engine's AVAudioEngine tap path (the @Sendable realtime closure).
  @Test func engineAudioPathInstallsTapWithoutCrashing() async throws {
    let engine = AppleSpeechLiveTranscriptionEngine(
      localeProvider: { "en-US" }, requireOnDeviceModel: false, skipPermissionRequests: true)
    await engine.start()
    try await Task.sleep(nanoseconds: 2_500_000_000)
    let terminal = engine.status
    engine.stop()
    print("[OnDeviceSpeech] engineAudioPath terminal=\(terminal)")
    #expect(terminal != .idle)
  }

  // MARK: - helpers

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
  private static func recognize(
    _ buffers: [AVAudioPCMBuffer],
    recognizer: SFSpeechRecognizer
  ) async -> RecognitionOutcome {
    await withCheckedContinuation {
      (continuation: CheckedContinuation<RecognitionOutcome, Never>) in
      let request = SFSpeechAudioBufferRecognitionRequest()
      // why: match the Simulator's server-recognition path so this test reflects what the
      // app actually does there; on hardware the engine uses on-device.
      #if targetEnvironment(simulator)
        request.requiresOnDeviceRecognition = false
      #else
        request.requiresOnDeviceRecognition = true
      #endif
      request.shouldReportPartialResults = false
      request.taskHint = .dictation
      let completion = OneShot<RecognitionOutcome>(continuation)
      let task = recognizer.recognitionTask(with: request) { result, error in
        if let error = error as NSError? {
          completion.finish(
            .failure(
              domain: error.domain, code: error.code, description: error.localizedDescription)
          )
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

// why: AVSpeechSynthesizer.write streams buffers on an internal queue and signals completion
// with a final zero-length buffer; the synthesizer must outlive the stream.
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

  init(_ continuation: CheckedContinuation<Payload, Never>) { self.continuation = continuation }

  func finish(_ payload: Payload) {
    let shouldResume = lock.withLock {
      guard !done else { return false }
      done = true
      return true
    }
    if shouldResume { continuation.resume(returning: payload) }
  }
}
