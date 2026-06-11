@preconcurrency import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech

@MainActor
@Observable
final class CallsignDictationService {
  enum Status: Equatable {
    case idle
    case starting
    case listening
    case unavailable(String)
  }

  private(set) var status: Status = .idle {
    didSet {
      switch status {
      case .idle:
        DspeechLog.engine.info("callsign dictation status=idle")
      case .starting:
        DspeechLog.engine.info("callsign dictation status=starting")
      case .listening:
        DspeechLog.engine.info("callsign dictation status=listening")
      case .unavailable(let reason):
        DspeechLog.engine.error("callsign dictation status=unavailable reason=\(reason)")
      }
    }
  }
  private(set) var liveTranscript: String = ""

  private let localeProvider: @MainActor () -> String?
  private let authorization: any CallsignSpeechAuthorization
  private let recognizerFactory: @MainActor (String) -> (any CallsignSpeechRecognizing)?
  private let audioCapture: any CallsignAudioCapturing
  private let arbiter: AudioCaptureArbiter
  private var recognizer: (any CallsignSpeechRecognizing)?
  private var task: (any CallsignRecognitionTasking)?
  private var activeSessionID: UUID?
  private var captureLeaseAcquired = false
  private var captureStartAttempted = false
  private var captureStarted = false
  private var captureContinuation: AsyncStream<CallsignCapturedBuffer>.Continuation?
  private var consumeTask: Task<Void, Never>?

  init(
    localeIdentifier: String = "en-US",
    localeProvider: (@MainActor () -> String?)? = nil,
    authorization: any CallsignSpeechAuthorization = SystemCallsignSpeechAuthorization(),
    recognizerFactory: @escaping @MainActor (String) -> (any CallsignSpeechRecognizing)? = {
      AppleCallsignSpeechRecognizer(localeIdentifier: $0)
    },
    audioCapture: any CallsignAudioCapturing = AVAudioEngineCallsignAudioCapture(),
    arbiter: AudioCaptureArbiter = .shared
  ) {
    self.localeProvider = localeProvider ?? { localeIdentifier }
    self.authorization = authorization
    self.recognizerFactory = recognizerFactory
    self.audioCapture = audioCapture
    self.arbiter = arbiter
  }

  var isListening: Bool { status == .listening }
  private var isStarting: Bool { status == .starting }
  private var isActive: Bool { isStarting || isListening }

  var unavailableReason: String? {
    if case .unavailable(let reason) = status { return reason }
    return nil
  }

  func toggle() async {
    if isActive { stop() } else { await start() }
  }

  func start() async {
    guard !isActive else {
      DspeechLog.engine.debug("callsign dictation start ignored reason=already-active")
      return
    }
    guard let localeIdentifier = localeProvider() else {
      DspeechLog.engine.error(
        "callsign dictation start failed reason=recognition-locale-unavailable"
      )
      status = .unavailable(String(localized: "No recognition language available."))
      return
    }
    DspeechLog.engine.info(
      "callsign dictation start requested locale=\(localeIdentifier, privacy: .public)"
    )
    guard arbiter.acquire(.callsignDictation) else {
      DspeechLog.engine.error("callsign dictation start failed reason=capture-session-busy")
      status = .unavailable(
        String(
          localized:
            "Audio capture is already in use. Stop transcription before using voice entry."))
      return
    }
    captureLeaseAcquired = true
    let sessionID = UUID()
    activeSessionID = sessionID
    status = .starting
    liveTranscript = ""

    guard await authorization.requestSpeechAuthorization() else {
      DspeechLog.engine.error("callsign dictation start failed reason=speech-permission-denied")
      failBeforeCapture(
        String(localized: "No speech recognition access. Allow it in Settings."),
        sessionID: sessionID
      )
      return
    }
    guard isCurrent(sessionID) else { return }
    guard await authorization.requestMicrophonePermission() else {
      DspeechLog.engine.error("callsign dictation start failed reason=microphone-permission-denied")
      failBeforeCapture(
        String(localized: "No microphone access. Allow it in Settings."),
        sessionID: sessionID
      )
      return
    }
    guard isCurrent(sessionID) else { return }
    guard let recognizer = recognizerFactory(localeIdentifier), recognizer.isAvailable else {
      DspeechLog.engine.error("callsign dictation start failed reason=recognizer-unavailable")
      failBeforeCapture(
        String(localized: "Speech recognition isn't available on this device."),
        sessionID: sessionID)
      return
    }
    guard recognizer.supportsOnDeviceRecognition else {
      DspeechLog.engine.error(
        "callsign dictation start failed reason=on-device-model-missing locale=\(localeIdentifier, privacy: .public)"
      )
      failBeforeCapture(
        String(
          localized:
            "Offline recognition for \(localeIdentifier) is not installed. Voice entry of the callsign requires a local model."
        ),
        sessionID: sessionID
      )
      return
    }
    self.recognizer = recognizer

    do {
      captureStartAttempted = true
      try begin(recognizer: recognizer, sessionID: sessionID)
      guard isCurrent(sessionID) else { return }
      status = .listening
      DspeechLog.engine.info("callsign dictation listening")
    } catch {
      DspeechLog.engine.error(
        "callsign dictation start failed reason=capture-start-failed error=\(error.localizedDescription)"
      )
      failAfterCapture(
        String(localized: "Couldn’t start recording: \(error.localizedDescription)"),
        sessionID: sessionID)
    }
  }

  func stop() {
    guard isActive else {
      DspeechLog.engine.debug("callsign dictation stop ignored reason=not-active")
      return
    }
    DspeechLog.engine.info("callsign dictation stop requested")
    cleanup()
    status = .idle
  }

  private func begin(recognizer: any CallsignSpeechRecognizing, sessionID: UUID) throws {
    let (captureStream, audioContinuation) = AsyncStream<CallsignCapturedBuffer>.makeStream(
      bufferingPolicy: .unbounded
    )
    captureContinuation = audioContinuation
    consumeTask = Task { @MainActor [weak self] in
      for await captured in captureStream {
        guard let self, self.isCurrent(sessionID), let recognizer = self.recognizer else { break }
        recognizer.append(captured.buffer)
      }
    }

    task = recognizer.startRecognition(contextualStrings: ATCContextualVocabulary.strings()) {
      [weak self] update in
      Task { @MainActor [weak self] in
        self?.handle(update: update, sessionID: sessionID)
      }
    }
    DspeechLog.engine.info("callsign recognition task installed")

    do {
      try audioCapture.start { buffer in
        guard let copy = buffer.dspeechDeepCopy() else { return }
        audioContinuation.yield(CallsignCapturedBuffer(buffer: copy))
      }
      captureStarted = true
      DspeechLog.engine.info("callsign dictation capture started")
    } catch {
      DspeechLog.engine.error(
        "callsign dictation capture failed error=\(error.localizedDescription)"
      )
      captureContinuation?.finish()
      captureContinuation = nil
      consumeTask?.cancel()
      consumeTask = nil
      throw error
    }
  }

  private func cleanup() {
    DspeechLog.engine.info("callsign dictation cleanup started")
    activeSessionID = nil
    let deactivateSession = releaseCaptureLease()
    if captureStarted {
      audioCapture.stop(deactivateSession: deactivateSession)
    } else if captureStartAttempted {
      audioCapture.stop(deactivateSession: deactivateSession)
    }
    captureStarted = false
    captureStartAttempted = false
    captureContinuation?.finish()
    captureContinuation = nil
    consumeTask?.cancel()
    consumeTask = nil
    recognizer?.endAudio()
    task?.cancel()
    task = nil
    recognizer = nil
    DspeechLog.engine.info("callsign dictation cleanup finished")
  }

  private func releaseCaptureLease() -> Bool {
    guard captureLeaseAcquired else { return false }
    captureLeaseAcquired = false
    return arbiter.release(.callsignDictation)
  }

  private func handle(update: CallsignRecognitionUpdate, sessionID: UUID) {
    guard isCurrent(sessionID), isActive else { return }
    if let text = update.text { liveTranscript = text }
    guard update.isFinished else { return }
    if let hardError = update.hardError {
      DspeechLog.engine.error("callsign recognition task finished hardError=\(hardError)")
    } else {
      DspeechLog.engine.info("callsign recognition task finished")
    }
    cleanup()
    if let hardError = update.hardError {
      status = .unavailable(String(localized: "Couldn’t recognize speech: \(hardError)"))
    } else {
      status = .idle
    }
  }

  private func isCurrent(_ sessionID: UUID) -> Bool {
    activeSessionID == sessionID
  }

  private func failBeforeCapture(_ reason: String, sessionID: UUID) {
    guard isCurrent(sessionID) else { return }
    activeSessionID = nil
    _ = releaseCaptureLease()
    status = .unavailable(reason)
  }

  private func failAfterCapture(_ reason: String, sessionID: UUID) {
    guard isCurrent(sessionID) else { return }
    cleanup()
    status = .unavailable(reason)
  }
}

private struct CallsignCapturedBuffer: @unchecked Sendable {
  // why: every buffer is deep-copied inside the realtime tap before it enters the stream, and
  // only the MainActor consumer reads/appends it before cleanup finishes the stream.
  let buffer: AVAudioPCMBuffer
}

@MainActor
protocol CallsignSpeechAuthorization {
  func requestSpeechAuthorization() async -> Bool
  func requestMicrophonePermission() async -> Bool
}

struct SystemCallsignSpeechAuthorization: CallsignSpeechAuthorization {
  func requestSpeechAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }

  func requestMicrophonePermission() async -> Bool {
    if #available(iOS 17.0, *) {
      return await AVAudioApplication.requestRecordPermission()
    } else {
      return await withCheckedContinuation { continuation in
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          continuation.resume(returning: granted)
        }
      }
    }
  }
}

struct CallsignRecognitionUpdate: Sendable {
  let text: String?
  let isFinished: Bool
  let hardError: String?
}

@MainActor
protocol CallsignRecognitionTasking {
  func cancel()
}

@MainActor
protocol CallsignSpeechRecognizing: AnyObject {
  var isAvailable: Bool { get }
  var supportsOnDeviceRecognition: Bool { get }
  func startRecognition(
    contextualStrings: [String],
    onUpdate: @escaping @Sendable (CallsignRecognitionUpdate) -> Void
  )
    -> any CallsignRecognitionTasking
  func append(_ buffer: AVAudioPCMBuffer)
  func endAudio()
}

@MainActor
protocol CallsignAudioCapturing {
  func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
  func stop(deactivateSession: Bool)
}

@MainActor
private final class AppleCallsignSpeechRecognizer: CallsignSpeechRecognizing {
  private let recognizer: SFSpeechRecognizer
  private var request: SFSpeechAudioBufferRecognitionRequest?

  init?(localeIdentifier: String) {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
      return nil
    }
    self.recognizer = recognizer
  }

  var isAvailable: Bool { recognizer.isAvailable }
  var supportsOnDeviceRecognition: Bool { recognizer.supportsOnDeviceRecognition }

  func startRecognition(
    contextualStrings: [String],
    onUpdate: @escaping @Sendable (CallsignRecognitionUpdate) -> Void
  )
    -> any CallsignRecognitionTasking
  {
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = true
    request.taskHint = .dictation
    request.contextualStrings = contextualStrings
    self.request = request

    let task = recognizer.recognitionTask(with: request) { result, error in
      let text = result?.bestTranscription.formattedString
      let hardError = Self.hardError(from: error)
      onUpdate(
        CallsignRecognitionUpdate(
          text: text,
          isFinished: (result?.isFinal ?? false) || error != nil,
          hardError: hardError
        )
      )
    }
    return AppleCallsignRecognitionTask(task: task)
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    request?.append(buffer)
  }

  func endAudio() {
    request?.endAudio()
    request = nil
  }

  private nonisolated static func hardError(from error: Error?) -> String? {
    guard let ns = error as NSError? else { return nil }
    if ns.domain == "kAFAssistantErrorDomain", ns.code == 1110 {
      return nil
    }
    return "\(ns.domain)#\(ns.code) \(ns.localizedDescription)"
  }
}

@MainActor
private struct AppleCallsignRecognitionTask: CallsignRecognitionTasking {
  let task: SFSpeechRecognitionTask
  func cancel() { task.cancel() }
}

@MainActor
private final class AVAudioEngineCallsignAudioCapture: CallsignAudioCapturing {
  private let audioEngine = AVAudioEngine()
  private var sessionActivated = false

  func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
    do {
      let session = AVAudioSession.sharedInstance()
      DspeechLog.engine.info("callsign audio session activation requested")
      try session.setActive(true)
      sessionActivated = true
      DspeechLog.engine.info("callsign audio session activation succeeded")

      let inputNode = audioEngine.inputNode
      let recordingFormat = inputNode.outputFormat(forBus: 0)
      guard recordingFormat.channelCount > 0, recordingFormat.sampleRate > 0 else {
        DspeechLog.engine.error(
          "callsign audio tap install failed reason=invalid-input-format sampleRate=\(recordingFormat.sampleRate, privacy: .public) channels=\(recordingFormat.channelCount, privacy: .public)"
        )
        throw CallsignAudioCaptureError.invalidInputFormat
      }

      inputNode.removeTap(onBus: 0)
      inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
        onBuffer(buffer)
      }
      DspeechLog.engine.info(
        "callsign audio tap installed sampleRate=\(recordingFormat.sampleRate, privacy: .public) channels=\(recordingFormat.channelCount, privacy: .public)"
      )
      audioEngine.prepare()
      try audioEngine.start()
      DspeechLog.engine.info("callsign audio engine started")
    } catch {
      DspeechLog.engine.error(
        "callsign audio capture start failed error=\(error.localizedDescription)"
      )
      stop(deactivateSession: false)
      throw error
    }
  }

  func stop(deactivateSession: Bool) {
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    audioEngine.inputNode.removeTap(onBus: 0)
    if deactivateSession, sessionActivated {
      DspeechLog.engine.info("callsign audio session deactivation requested")
      do {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        DspeechLog.engine.info("callsign audio session deactivation succeeded")
      } catch {
        DspeechLog.engine.error(
          "callsign audio session deactivation failed error=\(error.localizedDescription)"
        )
      }
      sessionActivated = false
    }
  }
}

enum CallsignAudioCaptureError: Error {
  case invalidInputFormat
}
