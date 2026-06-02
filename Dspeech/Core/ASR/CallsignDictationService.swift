@preconcurrency import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech

@MainActor
@Observable
final class CallsignDictationService {
  enum Status: Equatable {
    case idle
    case listening
    case unavailable(String)
  }

  private(set) var status: Status = .idle
  private(set) var liveTranscript: String = ""

  private let localeIdentifier: String
  private let audioEngine = AVAudioEngine()
  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?

  init(localeIdentifier: String = "en-US") {
    self.localeIdentifier = localeIdentifier
  }

  var isListening: Bool { status == .listening }

  var unavailableReason: String? {
    if case .unavailable(let reason) = status { return reason }
    return nil
  }

  func toggle() async {
    if isListening { stop() } else { await start() }
  }

  func start() async {
    guard !isListening else { return }
    liveTranscript = ""

    guard await Self.requestSpeechAuthorization() else {
      status = .unavailable("Нет доступа к распознаванию речи. Разрешите его в Настройках.")
      return
    }
    guard await Self.requestMicrophonePermission() else {
      status = .unavailable("Нет доступа к микрофону. Разрешите его в Настройках.")
      return
    }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
      recognizer.isAvailable
    else {
      status = .unavailable("Распознаватель речи недоступен на этом устройстве.")
      return
    }
    guard recognizer.supportsOnDeviceRecognition else {
      status = .unavailable(
        "Офлайн-распознавание для \(localeIdentifier) не установлено. Голосовой ввод позывного требует локальной модели."
      )
      return
    }
    self.recognizer = recognizer

    do {
      try begin(recognizer: recognizer)
      status = .listening
    } catch {
      status = .unavailable("Не удалось запустить запись: \(error.localizedDescription)")
      cleanup()
    }
  }

  func stop() {
    guard isListening else { return }
    cleanup()
    status = .idle
  }

  private func begin(recognizer: SFSpeechRecognizer) throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
    try session.setActive(true, options: .notifyOthersOnDeactivation)

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = true
    request.taskHint = .dictation
    self.request = request

    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)
    inputNode.removeTap(onBus: 0)
    let tapRequest = request
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) {
      @Sendable buffer, _ in
      tapRequest.append(buffer)
    }
    audioEngine.prepare()
    try audioEngine.start()

    task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
      let text = result?.bestTranscription.formattedString
      let finished = (result?.isFinal ?? false) || error != nil
      // why: surface a real recognition fault instead of silently returning to .idle
      // (which looks identical to "never started"); a "no speech" timeout (1110) is a
      // clean end, not a fault.
      let hardError: String?
      if let ns = error as NSError?, !(ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110) {
        hardError = "\(ns.domain)#\(ns.code) \(ns.localizedDescription)"
      } else {
        hardError = nil
      }
      Task { @MainActor [weak self] in
        guard let self, self.isListening else { return }
        if let text { self.liveTranscript = text }
        guard finished else { return }
        self.cleanup()
        if let hardError {
          self.status = .unavailable("Не удалось распознать речь: \(hardError)")
        } else {
          self.status = .idle
        }
      }
    }
  }

  private func cleanup() {
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    audioEngine.inputNode.removeTap(onBus: 0)
    request?.endAudio()
    task?.cancel()
    task = nil
    request = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private nonisolated static func requestSpeechAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }

  private nonisolated static func requestMicrophonePermission() async -> Bool {
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
