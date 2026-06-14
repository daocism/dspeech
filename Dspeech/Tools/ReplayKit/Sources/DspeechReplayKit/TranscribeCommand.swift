@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

enum TranscribeCommand {
  static let usage = """
    Usage: dspeech-replay transcribe --audio <wav> --locale <locale> [--engine apple] [--callsign <raw>] [--gap <seconds>] [--simulate-restart <seconds>] [--replay-tail on|off] [--chunk-seconds <seconds>] [--emit-partials on|off]
    """

  static func run(_ arguments: [String]) async throws -> Int32 {
    let options = try TranscribeArguments.parse(arguments)
    if options.engine == "whisperkit" {
      guard options.restartSeconds.isEmpty else {
        throw ReplayKitError.invalidArguments(
          "--simulate-restart mirrors the Apple task-recycle path; not applicable to whisperkit"
        )
      }
      try await WhisperKitTranscribe.run(options: options)
      return 0
    }
    let authorizationStatus = SpeechAuthorization.request()
    guard authorizationStatus == .authorized else {
      fputs(
        "Speech recognition authorization is \(SpeechAuthorization.describe(authorizationStatus)); expected authorized.\n",
        stderr
      )
      return 3
    }
    try await TranscribeRunner(options: options).run()
    return 0
  }
}

struct TranscribeArguments: Sendable {
  let audioURL: URL
  let localeIdentifier: String
  let callSign: String?
  let restartSeconds: [Double]
  let replayTailEnabled: Bool
  let chunkSeconds: Double
  let emitPartials: Bool
  let transmissionGapSeconds: Double
  let engine: String
  let silenceRestart: Bool

  static func parse(_ arguments: [String]) throws -> TranscribeArguments {
    var audioURL: URL?
    var localeIdentifier: String?
    var callSign: String?
    var restartSeconds: [Double] = []
    var replayTailEnabled = true
    var chunkSeconds = 0.1
    var emitPartials = true
    var transmissionGapSeconds = 3.5
    var engine = "apple"
    var silenceRestart = false
    var index = 0

    while index < arguments.count {
      switch arguments[index] {
      case "--audio":
        index += 1
        guard index < arguments.count else {
          throw ReplayKitError.invalidArguments("Missing value for --audio")
        }
        audioURL = URL(fileURLWithPath: arguments[index])
      case "--locale":
        index += 1
        guard index < arguments.count else {
          throw ReplayKitError.invalidArguments("Missing value for --locale")
        }
        localeIdentifier = arguments[index]
      case "--callsign":
        index += 1
        guard index < arguments.count else {
          throw ReplayKitError.invalidArguments("Missing value for --callsign")
        }
        callSign = arguments[index]
      case "--simulate-restart":
        index += 1
        guard index < arguments.count, let seconds = Double(arguments[index]), seconds >= 0 else {
          throw ReplayKitError.invalidArguments("Invalid value for --simulate-restart")
        }
        restartSeconds.append(seconds)
      case "--replay-tail":
        index += 1
        guard index < arguments.count, let value = ToggleArgument(arguments[index]) else {
          throw ReplayKitError.invalidArguments("Invalid value for --replay-tail")
        }
        replayTailEnabled = value.isOn
      case "--chunk-seconds":
        index += 1
        guard index < arguments.count, let seconds = Double(arguments[index]), seconds > 0 else {
          throw ReplayKitError.invalidArguments("Invalid value for --chunk-seconds")
        }
        chunkSeconds = seconds
      case "--emit-partials":
        index += 1
        guard index < arguments.count, let value = ToggleArgument(arguments[index]) else {
          throw ReplayKitError.invalidArguments("Invalid value for --emit-partials")
        }
        emitPartials = value.isOn
      case "--gap":
        index += 1
        guard index < arguments.count, let seconds = Double(arguments[index]), seconds > 0 else {
          throw ReplayKitError.invalidArguments("Invalid value for --gap")
        }
        transmissionGapSeconds = seconds
      case "--engine":
        index += 1
        guard index < arguments.count, ["apple", "whisperkit"].contains(arguments[index]) else {
          throw ReplayKitError.invalidArguments(
            "Invalid value for --engine (supported: apple, whisperkit)"
          )
        }
        engine = arguments[index]
      case "--silence-restart":
        index += 1
        guard index < arguments.count, let value = ToggleArgument(arguments[index]) else {
          throw ReplayKitError.invalidArguments("Invalid value for --silence-restart")
        }
        silenceRestart = value.isOn
      case "--help", "-h":
        throw ReplayKitError.invalidArguments(TranscribeCommand.usage)
      default:
        throw ReplayKitError.invalidArguments("Unknown transcribe argument: \(arguments[index])")
      }
      index += 1
    }

    guard let audioURL else { throw ReplayKitError.invalidArguments(TranscribeCommand.usage) }
    guard let localeIdentifier, !localeIdentifier.isEmpty else {
      throw ReplayKitError.invalidArguments(TranscribeCommand.usage)
    }

    return TranscribeArguments(
      audioURL: audioURL,
      localeIdentifier: localeIdentifier,
      callSign: callSign,
      restartSeconds: restartSeconds.sorted(),
      replayTailEnabled: replayTailEnabled,
      chunkSeconds: chunkSeconds,
      emitPartials: emitPartials,
      transmissionGapSeconds: transmissionGapSeconds,
      engine: engine,
      silenceRestart: silenceRestart
    )
  }
}

private enum ToggleArgument {
  case on
  case off

  init?(_ raw: String) {
    switch raw {
    case "on": self = .on
    case "off": self = .off
    default: return nil
    }
  }

  var isOn: Bool { self == .on }
}

private enum SpeechAuthorization {
  static func request() -> SFSpeechRecognizerAuthorizationStatus {
    let gate = SpeechAuthorizationGate()
    SFSpeechRecognizer.requestAuthorization { status in
      gate.set(status)
    }
    let deadline = Date().addingTimeInterval(30)
    while gate.status == nil && Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    return gate.status ?? .notDetermined
  }

  static func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: "not determined"
    case .denied: "denied"
    case .restricted: "restricted"
    case .authorized: "authorized"
    @unknown default: "unknown"
    }
  }
}

private final class SpeechAuthorizationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var storedStatus: SFSpeechRecognizerAuthorizationStatus?

  var status: SFSpeechRecognizerAuthorizationStatus? {
    lock.lock()
    let value = storedStatus
    lock.unlock()
    return value
  }

  func set(_ status: SFSpeechRecognizerAuthorizationStatus) {
    lock.lock()
    storedStatus = status
    lock.unlock()
  }
}

private struct TranscribeAudioChunk {
  let buffer: AVAudioPCMBuffer
  let sampleCount: Int
  let samples: [Float]
}

private struct TranscribeSegmentLine: Sendable {
  let startSeconds: Double
  let endSeconds: Double
  let confidence: Double
  let text: String
}

private struct TranscribeFinalEvent: Sendable {
  let text: String
  let endSeconds: Double
  let confidence: Double
  let segments: [TranscribeSegmentLine]
}

private struct TranscribeCallbackEvent: Sendable {
  let generation: Int
  let partialText: String?
  let final: TranscribeFinalEvent?
  let failure: TranscribeASRFailure?
}

private struct TranscribeASRFailure: Error, CustomStringConvertible, Sendable {
  let domain: String
  let code: Int
  let message: String

  var isBenignNoSpeech: Bool {
    domain == "kAFAssistantErrorDomain" && code == 1110
  }

  var description: String {
    "ASR error: \(domain)#\(code) \(message)"
  }
}

private final class TranscribeRunner {
  private let options: TranscribeArguments
  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private let callbackInbox = TranscribeCallbackInbox()
  private var generation = 0
  private var fedSampleCount = 0
  private var sampleRate = 0.0
  private var pendingPartial = ""
  private var emittedFinal = false
  private var endAudioSent = false
  private var completed = false
  private var failure: TranscribeASRFailure?
  private var replayTail = TranscribeReplayTail(maxDurationSeconds: 1.0, maxBufferCount: 96)
  private var nextRestartIndex = 0
  private var needsBenignRestart = false
  private var assembler: TransmissionAssembler
  private var closedTransmissions: [Transmission] = []
  // why: emulate the live engine's silence-driven recognition restart. SFSpeech .dictation never
  // self-finalizes on a pause, so the engine must DETECT the speech gap and recycle the request —
  // exactly what a continuous live mic needs (the 2026-06-14 "one card forever" device report).
  private let silenceSegmenter: EnergySilenceSegmenter?
  private let callSign: CallSign?

  init(options: TranscribeArguments) {
    self.options = options
    callSign = options.callSign.flatMap { CallSign(raw: $0) }
    silenceSegmenter =
      options.silenceRestart
      ? EnergySilenceSegmenter(
        minSpeechSeconds: 0.3, minSilenceSeconds: 1.0, maxWindowSeconds: 18,
        requireSpeechForMaxWindow: true)
      : nil
    var classifier = TransmissionClassifier(
      configuredCallSign: options.callSign.flatMap { CallSign(raw: $0) },
      localeIdentifier: options.localeIdentifier,
      voicePackActive: false
    )
    assembler = TransmissionAssembler(
      config: TransmissionAssemblerConfig(
        transmissionGapSeconds: options.transmissionGapSeconds
      ),
      localeIdentifier: options.localeIdentifier,
      classify: { text, speakers, endedAt in
        classifier.classify(text: text, speakers: speakers, endedAt: endedAt)
      }
    )
  }

  private func assemble(_ input: TransmissionAssemblerInput) {
    for update in assembler.process(input) {
      record(update)
    }
  }

  private func record(_ update: TransmissionUpdate) {
    if case .closed(let transmission) = update {
      closedTransmissions.append(transmission)
    }
  }

  private func finishAssembly(totalSeconds: Double) {
    for update in assembler.finish(at: Self.date(at: totalSeconds)) {
      record(update)
    }
  }

  private func printTransmissionBlocks() {
    let blocks = closedTransmissions.filter { !$0.text.isEmpty }
    print(
      "TRANSMISSIONS gap=\(Self.formatTime(options.transmissionGapSeconds))s locale=\(options.localeIdentifier) callsign=\(options.callSign ?? "<none>")"
    )
    guard !blocks.isEmpty else {
      print("  (no transmissions assembled)")
      return
    }
    for transmission in blocks {
      let kind = transmission.classification.isDisplayed ? "DISPLAYED" : "FILTERED "
      let text =
        callSign?.compacted(in: transmission.text, localeIdentifier: options.localeIdentifier)
        ?? transmission.text
      print(
        "[\(kind) \(Self.formatClock(transmission.startedAt))-\(Self.formatClock(transmission.endedAt))] «\(text)»  (reason: \(Self.describe(transmission.classification)))"
      )
    }
  }

  private static func date(at seconds: Double) -> Date {
    Date(timeIntervalSince1970: seconds)
  }

  private static func formatClock(_ date: Date) -> String {
    let seconds = date.timeIntervalSince1970
    let minutes = Int(seconds) / 60
    let remainder = seconds - Double(minutes * 60)
    return String(format: "%02d:%05.2f", minutes, remainder)
  }

  private static func describe(_ classification: TransmissionClassification) -> String {
    switch classification {
    case .displayed(let reason): reason.rawValue
    case .filtered(let reason): reason.rawValue
    }
  }

  func run() async throws {
    let audio = try PCM16WAVAudioReader().read(options.audioURL)
    sampleRate = audio.sampleRate
    let chunks = try Self.makeChunks(audio: audio, chunkSeconds: options.chunkSeconds)
    let totalSeconds = Double(audio.samples.count) / audio.sampleRate
    let locale = Locale(identifier: options.localeIdentifier)
    guard let recognizer = SFSpeechRecognizer(locale: locale) else {
      throw ReplayKitError.invalidFixture(
        "Speech recognizer unavailable for locale \(options.localeIdentifier)"
      )
    }
    guard recognizer.isAvailable else {
      throw ReplayKitError.invalidFixture(
        "Speech recognizer is not available for locale \(options.localeIdentifier)"
      )
    }
    guard recognizer.supportsOnDeviceRecognition else {
      throw ReplayKitError.invalidFixture(
        "On-device recognition asset is unavailable for locale \(options.localeIdentifier)"
      )
    }
    recognizer.defaultTaskHint = .dictation
    self.recognizer = recognizer
    try startRecognition(taskStartSeconds: 0)

    for chunk in chunks {
      appendChunk(chunk)
      await pace(seconds: options.chunkSeconds)
      if let segmenter = silenceSegmenter {
        switch segmenter.update(block: chunk.samples, sampleRate: sampleRate) {
        case .accumulate:
          break
        case .cutAfterSilence, .cutAtMaxWindow:
          segmenter.reset()
          try simulateRestart()
        }
      }
      while nextRestartIndex < options.restartSeconds.count
        && currentAudioSeconds >= options.restartSeconds[nextRestartIndex]
      {
        try simulateRestart()
        nextRestartIndex += 1
      }
      if needsBenignRestart {
        needsBenignRestart = false
        try simulateRestart()
      }
      if let failure { throw failure }
    }

    request?.endAudio()
    endAudioSent = true
    try await waitForCompletion(totalSeconds: totalSeconds)
    print("EVENT done     t=\(Self.formatTime(totalSeconds))")
    teardownRecognition()
    finishAssembly(totalSeconds: totalSeconds)
    printTransmissionBlocks()
  }

  private static func makeChunks(
    audio: SourceAudio,
    chunkSeconds: Double
  ) throws -> [TranscribeAudioChunk] {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: audio.sampleRate,
        channels: 1,
        interleaved: false
      )
    else {
      throw ReplayKitError.invalidFixture("Unable to create PCM format for replay audio")
    }
    let chunkSamples = max(1, Int((audio.sampleRate * chunkSeconds).rounded()))
    var chunks: [TranscribeAudioChunk] = []
    chunks.reserveCapacity((audio.samples.count + chunkSamples - 1) / chunkSamples)
    var cursor = 0
    while cursor < audio.samples.count {
      let count = min(chunkSamples, audio.samples.count - cursor)
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: format,
          frameCapacity: AVAudioFrameCount(count)
        )
      else {
        throw ReplayKitError.invalidFixture("Unable to allocate PCM buffer for replay audio")
      }
      buffer.frameLength = AVAudioFrameCount(count)
      guard let channel = buffer.floatChannelData?[0] else {
        throw ReplayKitError.invalidFixture("Unable to fill PCM buffer for replay audio")
      }
      audio.samples.withUnsafeBufferPointer { source in
        channel.update(from: source.baseAddress!.advanced(by: cursor), count: count)
      }
      chunks.append(
        TranscribeAudioChunk(
          buffer: buffer, sampleCount: count,
          samples: Array(audio.samples[cursor..<(cursor + count)])))
      cursor += count
    }
    return chunks
  }

  private func startRecognition(taskStartSeconds: Double) throws {
    guard let recognizer else {
      throw ReplayKitError.invalidFixture("Speech recognizer was not configured")
    }
    callbackInbox.removeAll()
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    request.addsPunctuation = true
    request.contextualStrings = ATCContextualVocabulary.strings(callSign: options.callSign)
    self.request = request
    generation += 1
    let activeGeneration = generation
    let inbox = callbackInbox
    task = recognizer.recognitionTask(with: request) { @Sendable result, error in
      let callback = Self.makeCallback(
        generation: activeGeneration,
        taskStartSeconds: taskStartSeconds,
        result: result,
        error: error
      )
      inbox.append(callback)
    }
  }

  private static func makeCallback(
    generation: Int,
    taskStartSeconds: Double,
    result: SFSpeechRecognitionResult?,
    error: Error?
  ) -> TranscribeCallbackEvent {
    let failure = (error as NSError?).map {
      TranscribeASRFailure(domain: $0.domain, code: $0.code, message: $0.localizedDescription)
    }
    guard let result else {
      return TranscribeCallbackEvent(
        generation: generation,
        partialText: nil,
        final: nil,
        failure: failure
      )
    }
    let transcription = result.bestTranscription
    if result.isFinal {
      let segments = transcription.segments.map { segment in
        TranscribeSegmentLine(
          startSeconds: taskStartSeconds + segment.timestamp,
          endSeconds: taskStartSeconds + segment.timestamp + segment.duration,
          confidence: Double(segment.confidence),
          text: segment.substring
        )
      }
      let text = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
      let endSeconds = segments.map(\.endSeconds).max() ?? taskStartSeconds
      let confidence = Self.averageConfidence(segments)
      return TranscribeCallbackEvent(
        generation: generation,
        partialText: nil,
        final: text.isEmpty
          ? nil
          : TranscribeFinalEvent(
            text: text,
            endSeconds: endSeconds,
            confidence: confidence,
            segments: segments
          ),
        failure: failure
      )
    }
    return TranscribeCallbackEvent(
      generation: generation,
      partialText: transcription.formattedString,
      final: nil,
      failure: failure
    )
  }

  private static func averageConfidence(_ segments: [TranscribeSegmentLine]) -> Double {
    guard !segments.isEmpty else { return 0 }
    return segments.map(\.confidence).reduce(0, +) / Double(segments.count)
  }

  private func appendChunk(_ chunk: TranscribeAudioChunk) {
    replayTail.append(chunk.buffer, sampleCount: chunk.sampleCount, sampleRate: sampleRate)
    request?.append(chunk.buffer)
    fedSampleCount += chunk.sampleCount
  }

  private func simulateRestart() throws {
    let restartSeconds = currentAudioSeconds
    let trimmedPartial = pendingPartial.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedPartial.isEmpty {
      printFinal(
        text: trimmedPartial,
        endSeconds: restartSeconds,
        confidence: 0,
        interim: true,
        segments: []
      )
      assemble(
        .fragment(
          segment: TranscriptSegment(
            text: trimmedPartial,
            confidence: 0,
            sourceLanguageCode: Self.languageCode(for: options.localeIdentifier),
            source: .replay,
            isInterimRestartCommit: true
          ),
          speaker: nil,
          at: Self.date(at: restartSeconds)
        )
      )
      emittedFinal = true
      pendingPartial = ""
    }
    let tail = options.replayTailEnabled ? replayTail.snapshot() : TranscribeReplayTailSnapshot()
    teardownRecognition()
    let replayedTailSeconds = tail.durationSeconds
    print(
      "EVENT restart  t=\(Self.formatTime(restartSeconds))  replayedTailSeconds=\(Self.formatTime(replayedTailSeconds))"
    )
    assemble(.taskRestart(at: Self.date(at: restartSeconds)))
    try startRecognition(taskStartSeconds: restartSeconds - replayedTailSeconds)
    for buffer in tail.buffers {
      request?.append(buffer)
    }
  }

  private static func languageCode(for localeIdentifier: String) -> String {
    Locale(identifier: localeIdentifier).language.languageCode?.identifier ?? localeIdentifier
  }

  private func handleCallback(_ callback: TranscribeCallbackEvent) {
    guard callback.generation == generation else { return }
    if let partialText = callback.partialText {
      pendingPartial = partialText
      if options.emitPartials
        && !partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        print(
          "EVENT partial  t=\(Self.formatTime(currentAudioSeconds))  «\(partialText)»"
        )
      }
    }
    if let final = callback.final {
      printFinal(
        text: final.text,
        endSeconds: final.endSeconds,
        confidence: final.confidence,
        interim: false,
        segments: final.segments
      )
      // why: live-partial feed times are load-dependent (a fast feed outruns the
      // recognizer and stamps everything at end-of-audio); the final's segment
      // timestamps are the audio-accurate speech evidence, so they drive the
      // assembler's open/keep-open instead.
      for segment in final.segments.sorted(by: { $0.startSeconds < $1.startSeconds }) {
        assemble(
          .partial(text: final.text, at: Self.date(at: segment.startSeconds))
        )
      }
      assemble(
        .fragment(
          segment: TranscriptSegment(
            text: final.text,
            confidence: final.confidence,
            sourceLanguageCode: Self.languageCode(for: options.localeIdentifier),
            source: .replay
          ),
          speaker: nil,
          at: Self.date(at: final.endSeconds)
        )
      )
      pendingPartial = ""
      emittedFinal = true
      if endAudioSent { completed = true }
    }
    if let callbackFailure = callback.failure {
      if callbackFailure.isBenignNoSpeech {
        // why: 1110 means "this request saw no speech yet", not a dead session —
        // the live engine reinstalls the recognition task and replays the tail.
        // Mirror it: recycle mid-feed, complete once all audio was delivered.
        if endAudioSent {
          completed = true
        } else {
          needsBenignRestart = true
        }
      } else {
        failure = callbackFailure
        completed = true
      }
    }
  }

  private func printFinal(
    text: String,
    endSeconds: Double,
    confidence: Double,
    interim: Bool,
    segments: [TranscribeSegmentLine]
  ) {
    print(
      "EVENT final    t=\(Self.formatTime(endSeconds))  conf=\(Self.formatConfidence(confidence))  interim=\(interim ? "true" : "false")  «\(text)»"
    )
    for segment in segments {
      print(
        "  SEG [\(Self.formatSegmentTime(segment.startSeconds))-\(Self.formatSegmentTime(segment.endSeconds))] conf=\(Self.formatConfidence(segment.confidence)) \(segment.text)"
      )
    }
  }

  private func waitForCompletion(totalSeconds: Double) async throws {
    let deadline = Date().addingTimeInterval(120)
    while !completed && failure == nil && Date() < deadline {
      await pace(seconds: 0.1)
    }
    if let failure { throw failure }
    guard completed else {
      throw ReplayKitError.invalidFixture(
        "Timed out waiting for final ASR result after \(Self.formatTime(totalSeconds))s of audio"
      )
    }
  }

  // why: feed pacing must be wall-clock real-time — an unpaced feed outruns the
  // recognizer, so a simulated restart cancels the task before its first result
  // and the successor sees only a burst+endAudio (returns 1110). Speech callbacks
  // arrive on their own dispatch queue into the inbox; no run-loop service needed.
  private func pace(seconds: Double) async {
    try? await Task.sleep(for: .seconds(seconds))
    drainCallbacks()
  }

  private func teardownRecognition() {
    generation += 1
    callbackInbox.removeAll()
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil
  }

  private func drainCallbacks() {
    for callback in callbackInbox.drain() {
      handleCallback(callback)
    }
  }

  private var currentAudioSeconds: Double {
    guard sampleRate > 0 else { return 0 }
    return Double(fedSampleCount) / sampleRate
  }

  private static func formatTime(_ value: Double) -> String {
    String(format: "%.2f", value)
  }

  private static func formatConfidence(_ value: Double) -> String {
    String(format: "%.2f", value)
  }

  private static func formatSegmentTime(_ value: Double) -> String {
    String(format: "%6.2f", value)
  }
}

private final class TranscribeCallbackInbox: @unchecked Sendable {
  private let lock = NSLock()
  private var callbacks: [TranscribeCallbackEvent] = []

  func append(_ callback: TranscribeCallbackEvent) {
    lock.lock()
    callbacks.append(callback)
    lock.unlock()
  }

  func drain() -> [TranscribeCallbackEvent] {
    lock.lock()
    let drained = callbacks
    callbacks.removeAll()
    lock.unlock()
    return drained
  }

  func removeAll() {
    lock.lock()
    callbacks.removeAll()
    lock.unlock()
  }
}

private struct TranscribeReplayTailSnapshot {
  let buffers: [AVAudioPCMBuffer]
  let durationSeconds: Double

  init(buffers: [AVAudioPCMBuffer] = [], durationSeconds: Double = 0) {
    self.buffers = buffers
    self.durationSeconds = durationSeconds
  }
}

private struct TranscribeReplayTail {
  private struct Entry {
    let buffer: AVAudioPCMBuffer
    let durationSeconds: Double
  }

  private let maxDurationSeconds: Double
  private let maxBufferCount: Int
  private var entries: [Entry] = []

  init(maxDurationSeconds: Double, maxBufferCount: Int) {
    self.maxDurationSeconds = max(0, maxDurationSeconds)
    self.maxBufferCount = max(0, maxBufferCount)
  }

  mutating func append(_ buffer: AVAudioPCMBuffer, sampleCount: Int, sampleRate: Double) {
    guard sampleCount > 0, sampleRate > 0, maxBufferCount > 0, maxDurationSeconds > 0 else {
      return
    }
    entries.append(Entry(buffer: buffer, durationSeconds: Double(sampleCount) / sampleRate))
    trim()
  }

  func snapshot() -> TranscribeReplayTailSnapshot {
    TranscribeReplayTailSnapshot(
      buffers: entries.map(\.buffer),
      durationSeconds: entries.reduce(0) { $0 + $1.durationSeconds }
    )
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
