@preconcurrency import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class VoiceEnrollmentRecorder {
  enum Status: Equatable {
    case idle
    case recording
    case unavailable(String)
  }

  static let targetSeconds: Double = 6

  private(set) var status: Status = .idle
  private(set) var collected: [Float] = []
  private(set) var captureSampleRate: Double = 16_000

  private let audioEngine = AVAudioEngine()

  var isRecording: Bool { status == .recording }

  var unavailableReason: String? {
    if case .unavailable(let reason) = status { return reason }
    return nil
  }

  func start() async {
    guard !isRecording else { return }
    collected = []

    guard await Self.requestMicrophonePermission() else {
      status = .unavailable("Нет доступа к микрофону. Разрешите его в Настройках.")
      return
    }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
      try session.setActive(true, options: .notifyOthersOnDeactivation)

      let inputNode = audioEngine.inputNode
      let format = inputNode.outputFormat(forBus: 0)
      // why: a 0 Hz / 0-channel input (Simulator, mic-denied, mid route-change) makes
      // installTap hard-crash deep in CoreAudio; bail to .unavailable instead.
      guard format.channelCount > 0, format.sampleRate > 0 else {
        status = .unavailable("Микрофон недоступен.")
        teardown()
        return
      }
      captureSampleRate = format.sampleRate
      inputNode.removeTap(onBus: 0)
      // why: format:nil — the tap uses the input bus's OWN current format. A separately-read
      // AVAudioFormat trips an NSException abort in AUGraphNodeBaseV3::CreateRecordingTap
      // ("required condition is false: format.sampleRate == hwFormat.sampleRate") when it
      // doesn't match the live hardware rate (.measurement mode reconfigures it).
      //
      // why: the `@Sendable` is LOAD-BEARING. This type is @MainActor, so a bare closure
      // here inherits @MainActor isolation; AVFAudio invokes the tap on its realtime
      // thread → swift_task_isCurrentExecutor(MainActor) false → dispatch_assert_queue_fail
      // (EXC_BREAKPOINT) on the first captured buffer. @Sendable makes it nonisolated so it
      // legally runs off-MainActor; it only hops to @MainActor via the Task below.
      inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) {
        @Sendable [weak self] buffer, _ in
        let mono = AppleSpeechLiveTranscriptionEngine.monoFloatSamples(from: buffer)
        Task { @MainActor [weak self] in
          guard let self, let mono else { return }
          self.collected.append(contentsOf: mono)
        }
      }
      audioEngine.prepare()
      try audioEngine.start()
      status = .recording
    } catch {
      status = .unavailable("Не удалось запустить запись: \(error.localizedDescription)")
      teardown()
    }
  }

  @discardableResult
  func stop() -> (samples: [Float], sampleRate: Double)? {
    guard isRecording else { return nil }
    teardown()
    status = .idle
    guard !collected.isEmpty else { return nil }
    return (collected, captureSampleRate)
  }

  private func teardown() {
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    audioEngine.inputNode.removeTap(onBus: 0)
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
