import Foundation

#if DEBUG
  @MainActor
  final class RenderStableScriptedLiveTranscriptionEngine: LiveTranscriptionEngine {
    private var continuation: AsyncStream<LiveTranscriptionEvent>.Continuation?
    private var finalTask: Task<Void, Never>?
    private(set) var status: LiveTranscriptionStatus = .idle
    // why: UI-test seam — drive a specific failure (e.g. a permission-denied banner) instead of the
    // normal scripted transcript, so the error/permission states are auditable in the sim.
    private let failCode: String?

    init(failCode: String? = nil) {
      self.failCode = failCode
    }

    static func makeFromLaunchArguments(
      _ arguments: [String] = CommandLine.arguments
    ) -> RenderStableScriptedLiveTranscriptionEngine? {
      guard ScriptedLiveTranscriptionEngine.makeFromLaunchArguments(arguments) != nil else {
        return nil
      }
      let failCode = arguments.firstIndex(of: "-dspeech.uitest.scripted-fail").flatMap {
        $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
      }
      return RenderStableScriptedLiveTranscriptionEngine(failCode: failCode)
    }

    func events() -> AsyncStream<LiveTranscriptionEvent> {
      AsyncStream<LiveTranscriptionEvent> { continuation in
        self.continuation = continuation
        continuation.yield(.status(self.status))
      }
    }

    func start() async {
      transition(to: .requestingPermission)
      if let failCode {
        transition(to: .failed(failCode))
        return
      }
      transition(to: .listening)
      continuation?.yield(.partial("Tower N123AB"))
      finalTask?.cancel()
      finalTask = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(nanoseconds: 2_500_000_000)
        } catch {
          return
        }
        guard let self, self.status == .listening else { return }
        self.continuation?.yield(
          .segment(
            TranscriptSegment(
              text: "Tower N123AB cleared for takeoff",
              confidence: 0.96,
              sourceLanguageCode: "en",
              source: .liveATC
            ), speaker: nil))
        self.transition(to: .stopped)
      }
    }

    func stop() {
      finalTask?.cancel()
      finalTask = nil
      transition(to: .stopped)
    }

    private func transition(to newStatus: LiveTranscriptionStatus) {
      status = newStatus
      continuation?.yield(.status(newStatus))
    }
  }
#endif
