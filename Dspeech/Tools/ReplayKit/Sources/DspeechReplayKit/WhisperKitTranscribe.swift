import Foundation
import WhisperKit

enum WhisperKitTranscribe {
  static let defaultModel = "large-v3-v20240930_626MB"

  static func run(options: TranscribeArguments) async throws {
    let audio = try PCM16WAVAudioReader().read(options.audioURL)
    guard audio.sampleRate == 16_000 else {
      throw ReplayKitError.invalidFixture(
        "WhisperKit engine requires 16kHz fixtures; got \(audio.sampleRate)Hz"
      )
    }
    let totalSeconds = Double(audio.samples.count) / audio.sampleRate
    let modelFolder = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".cache/dspeech-whisperkit", isDirectory: true)
    fputs("whisperkit: loading model \(Self.defaultModel) (downloads on first run)\n", stderr)
    let pipe = try await WhisperKit(
      WhisperKitConfig(
        model: Self.defaultModel,
        downloadBase: modelFolder,
        verbose: false,
        logLevel: .error
      )
    )
    let language = Locale(identifier: options.localeIdentifier)
      .language.languageCode?.identifier
    let results = try await pipe.transcribe(
      audioArray: audio.samples,
      decodeOptions: DecodingOptions(
        task: .transcribe,
        language: language,
        temperature: 0,
        wordTimestamps: true
      )
    )

    let collector = TranscriptionBlockCollector(options: options)
    for result in results {
      for segment in result.segments {
        let text = Self.cleanSegmentText(segment.text)
        guard !text.isEmpty else { continue }
        let confidence = Self.confidence(fromAverageLogProb: Double(segment.avgLogprob))
        print(
          "EVENT final    t=\(String(format: "%.2f", segment.end))  conf=\(String(format: "%.2f", confidence))  interim=false  «\(text)»"
        )
        if let words = segment.words {
          for word in words {
            print(
              "  SEG [\(String(format: "%6.2f", word.start))-\(String(format: "%6.2f", word.end))] conf=\(String(format: "%.2f", word.probability)) \(word.word.trimmingCharacters(in: .whitespaces))"
            )
          }
        }
        collector.addFragment(
          text: text,
          confidence: confidence,
          startSeconds: Double(segment.start),
          endSeconds: Double(segment.end),
          wordStartTimes: (segment.words ?? []).map { Double($0.start) }
        )
      }
    }
    print("EVENT done     t=\(String(format: "%.2f", totalSeconds))")
    collector.finishAndPrint(totalSeconds: totalSeconds)
  }

  // why: whisper emits special markers (<|startoftranscript|>, timestamps) inside
  // segment text in some decode paths; strip anything between <| |> plus whitespace.
  static func cleanSegmentText(_ raw: String) -> String {
    var text = raw
    while let open = text.range(of: "<|"),
      let close = text.range(of: "|>", range: open.upperBound..<text.endIndex)
    {
      text.removeSubrange(open.lowerBound..<close.upperBound)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func confidence(fromAverageLogProb value: Double) -> Double {
    min(1, max(0, exp(value)))
  }
}

final class TranscriptionBlockCollector {
  private let options: TranscribeArguments
  private var assembler: TransmissionAssembler
  private var closed: [Transmission] = []

  init(options: TranscribeArguments) {
    self.options = options
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

  func addFragment(
    text: String,
    confidence: Double,
    startSeconds: Double,
    endSeconds: Double,
    wordStartTimes: [Double]
  ) {
    // why: whisper delivers one final per segment — without intermediate
    // evidence a long segment would exceed the gap and self-close. Word start
    // times replay the live partial cadence: the transmission opens at the
    // segment's audio start and stays open through every spoken word.
    for wordStart in ([startSeconds] + wordStartTimes).sorted() {
      record(assembler.process(.partial(text: text, at: Date(timeIntervalSince1970: wordStart))))
    }
    let updates = assembler.process(
      .fragment(
        segment: TranscriptSegment(
          text: text,
          confidence: confidence,
          sourceLanguageCode: Locale(identifier: options.localeIdentifier)
            .language.languageCode?.identifier ?? options.localeIdentifier,
          source: .replay
        ),
        speaker: nil,
        at: Date(timeIntervalSince1970: endSeconds)
      )
    )
    record(updates)
  }

  func finishAndPrint(totalSeconds: Double) {
    record(assembler.finish(at: Date(timeIntervalSince1970: totalSeconds)))
    let blocks = closed.filter { !$0.text.isEmpty }
    print(
      "TRANSMISSIONS gap=\(String(format: "%.2f", options.transmissionGapSeconds))s locale=\(options.localeIdentifier) callsign=\(options.callSign ?? "<none>") engine=whisperkit"
    )
    guard !blocks.isEmpty else {
      print("  (no transmissions assembled)")
      return
    }
    for transmission in blocks {
      let kind = transmission.classification.isDisplayed ? "DISPLAYED" : "FILTERED "
      print(
        "[\(kind) \(Self.formatClock(transmission.startedAt))-\(Self.formatClock(transmission.endedAt))] «\(transmission.text)»  (reason: \(Self.describe(transmission.classification)))"
      )
    }
  }

  private func record(_ updates: [TransmissionUpdate]) {
    for update in updates {
      if case .closed(let transmission) = update {
        closed.append(transmission)
      }
    }
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
}
