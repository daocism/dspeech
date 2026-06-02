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
// why: .serialized — these tests share the process-wide AVAudioSession / mic; Swift
// Testing's default parallelism makes them contend (IPCAUClient failures, empty buffers,
// a crash). They must run one at a time, each owning the audio stack.
@Suite(.serialized)
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
      print("[OnDeviceSpeech] \(report)")
      #expect(recognizer != nil, "no SFSpeechRecognizer for \(identifier) — \(report)")
      #expect(available, "recognizer not available for \(identifier) — \(report)")
      #expect(onDevice, "on-device recognition unsupported for \(identifier) — \(report)")
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
      print("[OnDeviceSpeech] on-device transcript: \(text)")
      #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    case .failure(let domain, let code, let description):
      // why: 1110 "no speech detected" is acceptable — synthetic TTS audio does not
      // always latch the recognizer. Any OTHER hard error is a genuine on-device fault.
      let benignNoSpeech = domain == "kAFAssistantErrorDomain" && code == 1110
      print(
        "[OnDeviceSpeech] recognition outcome domain=\(domain) code=\(code) desc=\(description)")
      #expect(
        benignNoSpeech, "on-device recognition hard-errored: \(domain)#\(code) \(description)")
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
    let trailText = trail.joined()
    print("[OnDeviceSpeech] status trail: \(trailText) | terminal=\(terminal)")
    #expect(
      terminal == .listening,
      "engine failed to sustain listening through 4 s of silence; trail=\(trailText) terminal=\(terminal)"
    )
  }

  // Crash-repro that runs on the SIMULATOR too: the input-level meter installs an
  // AVAudioEngine tap with NO permission gate, so it reliably exercises the
  // CreateRecordingTap path that aborted (the 14:31 sim crash). Reaching the end without
  // the process aborting is the pass condition.
  @Test
  func inputLevelMeterInstallsTapWithoutCrashing() async throws {
    let meter = AVAudioEngineInputLevelMeter()
    let drain = Task { for await _ in meter.levels() { break } }
    try await Task.sleep(nanoseconds: 800_000_000)
    meter.stop()
    drain.cancel()
    #expect(Bool(true))  // process did not abort in installTap
  }

  // Crash-repro for the ASR engine's AVAudioEngine path, reachable on the Simulator via
  // requireOnDeviceModel:false. Skips if speech auth is undetermined (would prompt and
  // hang in a non-UI test); the meter test above covers the Simulator unconditionally.
  @Test
  func engineAudioPathInstallsTapWithoutCrashing() async throws {
    let engine = AppleSpeechLiveTranscriptionEngine(
      localeProvider: { "en-US" }, requireOnDeviceModel: false, skipPermissionRequests: true)
    await engine.start()
    try await Task.sleep(nanoseconds: 2_500_000_000)
    let terminal = engine.status
    engine.stop()
    print("[OnDeviceSpeech] engineAudioPath terminal=\(terminal)")
    #expect(terminal != .idle)  // start() ran to completion without aborting in the capture path
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
