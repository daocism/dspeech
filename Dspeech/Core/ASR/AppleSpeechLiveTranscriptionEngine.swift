@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation

@MainActor
final class AppleSpeechLiveTranscriptionEngine: LiveTranscriptionEngine {
    private(set) var status: LiveTranscriptionStatus = .idle {
        didSet { emit(.status(status)) }
    }

    private let localeIdentifier: String
    private let bufferGate: (any SpeechAudioBufferGate)?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var router: UtteranceWindowRouter<AVAudioPCMBuffer>?
    private let audioEngine = AVAudioEngine()

    // why: the segmenter cuts a decision window at a trailing-silence utterance edge
    // (>= minSilence after >= minSpeech of speech) or, failing that, at this
    // conservative max-window cap — keeping the prior 1.0 s ceiling as a strict upper
    // bound so this change is never a latency regression; sub-window tails fail open.
    private static let decisionWindowSeconds = 1.0
    private static let minSpeechSeconds = 0.25
    private static let minSilenceSeconds = 0.40
    private var continuation: AsyncStream<LiveTranscriptionEvent>.Continuation?

    init(localeIdentifier: String = "en-US", bufferGate: (any SpeechAudioBufferGate)? = nil) {
        self.localeIdentifier = localeIdentifier
        self.bufferGate = bufferGate
    }

    func events() -> AsyncStream<LiveTranscriptionEvent> {
        AsyncStream<LiveTranscriptionEvent> { continuation in
            self.continuation = continuation
            continuation.yield(.status(self.status))
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stop()
                }
            }
        }
    }

    func start() async {
        guard status != .listening else { return }
        status = .requestingPermission

        let speechAuthorized = await Self.requestSpeechAuthorization()
        guard speechAuthorized else {
            status = .failed("speech-permission-denied")
            return
        }

        let micAllowed = await Self.requestMicrophonePermission()
        guard micAllowed else {
            status = .failed("microphone-permission-denied")
            return
        }

        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            status = .failed("recognizer-unavailable")
            return
        }
        recognizer.defaultTaskHint = .dictation
        self.recognizer = recognizer

        do {
            try beginAudioSession()
            try startEngineAndTask(recognizer: recognizer)
            status = .listening
        } catch {
            status = .failed("start-failed: \(error.localizedDescription)")
            cleanup()
        }
    }

    func stop() {
        guard status == .listening || status == .ready || status == .requestingPermission else {
            return
        }
        cleanup()
        status = .stopped
    }

    private func beginAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startEngineAndTask(recognizer: SFSpeechRecognizer) throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        if bufferGate != nil {
            // why: the gate routes through the nonisolated identifier, so the heavy
            // classifier work runs off @MainActor; the router groups buffers into a
            // decision window, classifies the whole window once, and serializes the
            // append/discard in capture order so a slow earlier window can't let a
            // later one overtake it into Apple Speech.
            let segmenter = EnergySilenceSegmenter(
                minSpeechSeconds: Self.minSpeechSeconds,
                minSilenceSeconds: Self.minSilenceSeconds,
                maxWindowSeconds: Self.decisionWindowSeconds
            )
            router = UtteranceWindowRouter<AVAudioPCMBuffer>(
                segmenter: segmenter,
                classify: { [weak self] samples, sampleRate in
                    guard let self else { return .transcribe(reason: .classifierUnavailable) }
                    return try await self.routeSamples(samples, sampleRate: sampleRate)
                },
                append: { [weak self] buffer in self?.request?.append(buffer) }
            )
        } else {
            router = nil
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            let samples = Self.monoFloatSamples(from: buffer)
            let sampleRate = buffer.format.sampleRate
            Task { @MainActor [weak self] in
                self?.routeBuffer(buffer, samples: samples, sampleRate: sampleRate)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        let localePrefix = String(localeIdentifier.prefix(2))
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let event: LiveTranscriptionEvent?
            let isFinal: Bool
            if let result {
                let raw = result.bestTranscription.formattedString
                if result.isFinal {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        event = nil
                    } else {
                        let confidence = Self.averageConfidence(for: result.bestTranscription)
                        let segment = TranscriptSegment(
                            text: trimmed,
                            translatedText: nil,
                            confidence: confidence,
                            sourceLanguageCode: localePrefix,
                            source: .liveATC
                        )
                        event = .segment(segment)
                    }
                    isFinal = true
                } else {
                    event = .partial(raw)
                    isFinal = false
                }
            } else {
                event = nil
                isFinal = false
            }
            let terminal = isFinal || error != nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let event {
                    self.emit(event)
                }
                if terminal {
                    self.cleanup()
                    if self.status == .listening {
                        self.status = .stopped
                    }
                }
            }
        }
    }

    private func routeSamples(_ samples: [Float], sampleRate: Double) async throws -> PreTranscriptionRoutingDecision {
        guard let bufferGate else { return .transcribe(reason: .classifierUnavailable) }
        return try await bufferGate.route(samples: samples, sampleRate: sampleRate)
    }

    private func routeBuffer(_ buffer: AVAudioPCMBuffer, samples: [Float]?, sampleRate: Double) {
        guard let router else {
            request?.append(buffer)
            return
        }
        // why: a non-float / empty buffer can't be classified; route it through the
        // serial router with empty samples so it fails open to ASR while keeping FIFO
        // order with classified buffers ahead of and behind it.
        router.submit(buffer, samples: samples ?? [], sampleRate: sampleRate)
    }

    nonisolated static func monoFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channelData = buffer.floatChannelData else {
            return nil
        }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return nil }

        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        }

        var mono = [Float](repeating: 0, count: frameLength)
        for channel in 0..<channelCount {
            let pointer = channelData[channel]
            for frame in 0..<frameLength {
                mono[frame] += pointer[frame]
            }
        }
        let scale = 1.0 / Float(channelCount)
        for frame in 0..<frameLength {
            mono[frame] *= scale
        }
        return mono
    }

    private func emitFinalSegment(text: String, transcription: SFTranscription) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let confidence = Self.averageConfidence(for: transcription)
        let segment = TranscriptSegment(
            text: trimmed,
            translatedText: nil,
            confidence: confidence,
            sourceLanguageCode: String(localeIdentifier.prefix(2)),
            source: .liveATC
        )
        emit(.segment(segment))
    }

    private nonisolated static func averageConfidence(for transcription: SFTranscription) -> Double {
        let segments = transcription.segments
        guard !segments.isEmpty else { return 0.0 }
        let total = segments.reduce(0.0) { $0 + Double($1.confidence) }
        let avg = total / Double(segments.count)
        return avg > 0 ? avg : 0.5
    }

    private func cleanup() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        // why: finish() before nil-ing the request so any buffer still classifying
        // off-main can't append into an ended/released recognition request.
        router?.finish()
        router = nil
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func emit(_ event: LiveTranscriptionEvent) {
        continuation?.yield(event)
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
