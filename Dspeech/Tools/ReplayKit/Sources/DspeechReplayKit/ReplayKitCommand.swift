import Foundation
import os

enum DspeechLog {
  static let subsystem = "com.dspeech.replaykit"
  static let voiceFilter = Logger(subsystem: subsystem, category: "voice-filter")
  // why: ModelPackState.swift is symlinked into this tool and logs persist failures via
  // DspeechLog.modelPack; the stub must carry every category the symlinked sources reference.
  static let modelPack = Logger(subsystem: subsystem, category: "model-pack")
  // why: ParakeetModelInstaller.swift (symlinked here to reuse the pinned supply-chain manifest
  // for the host Parakeet arm) logs a persistence failure via DspeechLog.engine.
  static let engine = Logger(subsystem: subsystem, category: "engine")
}

enum ReplayKitError: Error, CustomStringConvertible {
  case invalidArguments(String)
  case invalidFixture(String)
  case missingFixture(String)
  case thresholdBreach([String])

  var description: String {
    switch self {
    case .invalidArguments(let message): message
    case .invalidFixture(let message): message
    case .missingFixture(let message): message
    case .thresholdBreach(let messages): messages.joined(separator: "\n")
    }
  }
}

struct ReplayManifest: Decodable {
  let fixtures: [ReplayFixture]
}

struct ReplayFixture: Decodable, Sendable {
  let fixture: String
  let transcript: String
  let expectedTranscriptAfterFilter: String
  let expectedPilotDiscard: Bool
  // why: real ATC fixtures whose human ground-truth transcript is not yet
  // available are flagged as `audioOnly`. They exercise the audio reader and
  // classifier paths but are excluded from WER / precision / recall / FDR
  // averages so the gate never compares against fabricated text.
  let audioOnly: Bool?
  // why: the recognition locale of this fixture's transcript — drives the gate's locale-aware
  // callsign decode (a French "un deux trois" matches only with fr-FR). nil/absent = English.
  let locale: String?

  var isAudioOnly: Bool { audioOnly ?? false }
}

struct ReplayThreshold: Decodable, Sendable {
  let maxAverageWER: Double
  let minPilotDiscardPrecision: Double
  let minPilotDiscardRecall: Double
  let maxFalseDiscardRate: Double

  static let `default` = ReplayThreshold(
    maxAverageWER: 0.30,
    minPilotDiscardPrecision: 0.90,
    minPilotDiscardRecall: 0.80,
    maxFalseDiscardRate: 0.05
  )

  func breaches(_ report: ReplayReport) -> [String] {
    var messages: [String] = []
    if report.averageWER > maxAverageWER {
      messages.append(
        "WER breach: avg \(Self.format(report.averageWER)) > max \(Self.format(maxAverageWER))"
      )
    }
    if report.pilotDiscardPrecision < minPilotDiscardPrecision {
      messages.append(
        "pilot-discard-precision breach: \(Self.format(report.pilotDiscardPrecision)) < min \(Self.format(minPilotDiscardPrecision))"
      )
    }
    if report.pilotDiscardRecall < minPilotDiscardRecall {
      messages.append(
        "pilot-discard-recall breach: \(Self.format(report.pilotDiscardRecall)) < min \(Self.format(minPilotDiscardRecall))"
      )
    }
    if report.falseDiscardRate > maxFalseDiscardRate {
      messages.append(
        "false-discard-rate breach: \(Self.format(report.falseDiscardRate)) > max \(Self.format(maxFalseDiscardRate))"
      )
    }
    return messages
  }

  private static func format(_ value: Double) -> String {
    String(format: "%.3f", value)
  }
}

struct SourceAudio: Sendable {
  let samples: [Float]
  let sampleRate: Double
}

struct PCM16WAVAudioReader: Sendable {
  func read(_ url: URL) throws -> SourceAudio {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ReplayKitError.missingFixture("Missing source audio: \(url.lastPathComponent)")
    }
    let data = try Data(contentsOf: url)
    guard data.count >= 44 else {
      throw ReplayKitError.invalidFixture("WAV fixture is too small: \(url.lastPathComponent)")
    }
    guard String(bytes: data[0..<4], encoding: .ascii) == "RIFF",
      String(bytes: data[8..<12], encoding: .ascii) == "WAVE"
    else {
      throw ReplayKitError.invalidFixture(
        "Fixture is not a RIFF/WAVE file: \(url.lastPathComponent)")
    }

    var offset = 12
    var sampleRate: UInt32?
    var channelCount: UInt16?
    var bitsPerSample: UInt16?
    var pcmData: Data?

    while offset + 8 <= data.count {
      let chunkID = String(bytes: data[offset..<(offset + 4)], encoding: .ascii)
      let chunkSize = Int(Self.readUInt32LE(data, offset: offset + 4))
      let chunkStart = offset + 8
      let chunkEnd = chunkStart + chunkSize
      guard chunkEnd <= data.count else {
        throw ReplayKitError.invalidFixture("WAV chunk exceeds file size: \(url.lastPathComponent)")
      }

      switch chunkID {
      case "fmt ":
        guard chunkSize >= 16 else {
          throw ReplayKitError.invalidFixture(
            "WAV fmt chunk is incomplete: \(url.lastPathComponent)")
        }
        let audioFormat = Self.readUInt16LE(data, offset: chunkStart)
        guard audioFormat == 1 else {
          throw ReplayKitError.invalidFixture(
            "Only PCM WAV fixtures are supported: \(url.lastPathComponent)")
        }
        channelCount = Self.readUInt16LE(data, offset: chunkStart + 2)
        sampleRate = Self.readUInt32LE(data, offset: chunkStart + 4)
        bitsPerSample = Self.readUInt16LE(data, offset: chunkStart + 14)
      case "data":
        pcmData = data.subdata(in: chunkStart..<chunkEnd)
      default:
        break
      }

      offset = chunkEnd + (chunkSize % 2)
    }

    guard let sampleRate, let channelCount, let bitsPerSample, let pcmData else {
      throw ReplayKitError.invalidFixture(
        "WAV fixture is missing fmt or data chunk: \(url.lastPathComponent)")
    }
    guard channelCount > 0 else {
      throw ReplayKitError.invalidFixture("WAV fixture has no channels: \(url.lastPathComponent)")
    }
    guard bitsPerSample == 16 else {
      throw ReplayKitError.invalidFixture(
        "Only 16-bit PCM WAV fixtures are supported: \(url.lastPathComponent)")
    }

    let bytesPerFrame = Int(channelCount) * 2
    guard pcmData.count >= bytesPerFrame, pcmData.count % bytesPerFrame == 0 else {
      throw ReplayKitError.invalidFixture(
        "WAV data chunk has invalid frame alignment: \(url.lastPathComponent)")
    }

    var samples: [Float] = []
    samples.reserveCapacity(pcmData.count / bytesPerFrame)
    var frameOffset = 0
    while frameOffset < pcmData.count {
      var sum = Float(0)
      for channel in 0..<Int(channelCount) {
        let sampleOffset = frameOffset + channel * 2
        let raw = Int16(bitPattern: Self.readUInt16LE(pcmData, offset: sampleOffset))
        sum += Float(raw) / Float(Int16.max)
      }
      samples.append(sum / Float(channelCount))
      frameOffset += bytesPerFrame
    }

    return SourceAudio(samples: samples, sampleRate: Double(sampleRate))
  }

  private static func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }

  private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
    UInt32(data[offset])
      | (UInt32(data[offset + 1]) << 8)
      | (UInt32(data[offset + 2]) << 16)
      | (UInt32(data[offset + 3]) << 24)
  }
}

struct SyntheticReplaySpeakerIdentifier: LocalSpeakerIdentifier {
  let availability: LocalSpeakerIdentifierAvailability = .available
  let embeddingDimension = 4

  func enroll(samples: [Float], sampleRate: Double) async throws -> VoicePrintVector {
    _ = samples
    _ = sampleRate
    return VoicePrintVector(values: [1, 0, 0, 0], quality: 0.95)
  }

  func classify(
    samples: [Float],
    sampleRate: Double,
    profiles: [PilotVoiceProfile]
  ) async throws -> SpeakerMatchDecision {
    _ = sampleRate
    let vector: VoicePrintVector
    let averageMagnitude = averageMagnitude(samples)
    if samples.isEmpty {
      return .insufficientSpeech
    }
    if averageMagnitude >= 0.80 {
      vector = VoicePrintVector(values: [1, 0, 0, 0], quality: 0.95)
    } else if averageMagnitude >= 0.55 {
      vector = VoicePrintVector(values: [0.7, 0.7, 0, 0], quality: 0.95)
    } else {
      vector = VoicePrintVector(values: [0, 1, 0, 0], quality: 0.95)
    }
    return SpeakerMatcher.match(candidate: vector, profiles: profiles)
  }

  private func averageMagnitude(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    return samples.reduce(Float(0)) { $0 + abs($1) } / Float(samples.count)
  }
}

struct ReplayVoiceFilterStorage: VoiceFilterStorage {
  let profiles: [PilotVoiceProfile]
  let callSign: CallSign?
  let config: ATCTranscriptGateConfig
  let enabled: Bool

  func loadProfiles() -> [PilotVoiceProfile] { profiles }
  func saveProfiles(_ profiles: [PilotVoiceProfile]) { _ = profiles }
  func loadCallSign() -> CallSign? { callSign }
  func saveCallSign(_ callSign: CallSign?) { _ = callSign }
  func loadGateConfig() -> ATCTranscriptGateConfig { config }
  func saveGateConfig(_ config: ATCTranscriptGateConfig) { _ = config }
  func loadEnabled() -> Bool { enabled }
  func saveEnabled(_ enabled: Bool) { _ = enabled }
}

struct ReplayModelPackStorage: ModelPackStateStorage {
  let state: ModelPackState

  func loadState() -> ModelPackState { state }
  func saveState(_ state: ModelPackState) { _ = state }
}

struct ReplayMetrics: Sendable {
  let fixture: String
  let wer: Double
  let expectedPilotDiscard: Bool
  let actualPilotDiscard: Bool
  let audioOnly: Bool
  let speakerPath: String
  let textGateDecision: String
}

struct ReplayReport: Sendable {
  let rows: [ReplayMetrics]

  private var scoredRows: [ReplayMetrics] { rows.filter { !$0.audioOnly } }

  var averageWER: Double {
    let scored = scoredRows
    guard !scored.isEmpty else { return 0 }
    return scored.map(\.wer).reduce(0, +) / Double(scored.count)
  }

  var pilotDiscardPrecision: Double {
    let actual = scoredRows.filter(\.actualPilotDiscard)
    guard !actual.isEmpty else { return 1 }
    let correct = actual.filter(\.expectedPilotDiscard).count
    return Double(correct) / Double(actual.count)
  }

  var pilotDiscardRecall: Double {
    let expected = scoredRows.filter(\.expectedPilotDiscard)
    guard !expected.isEmpty else { return 1 }
    let correct = expected.filter(\.actualPilotDiscard).count
    return Double(correct) / Double(expected.count)
  }

  var falseDiscardRate: Double {
    let expectedKept = scoredRows.filter { !$0.expectedPilotDiscard }
    guard !expectedKept.isEmpty else { return 0 }
    let falseDiscards = expectedKept.filter(\.actualPilotDiscard).count
    return Double(falseDiscards) / Double(expectedKept.count)
  }

  func csv() -> String {
    let header =
      "fixture,WER,pilot-discard-precision,pilot-discard-recall,false-discard-rate,speaker-path,text-gate-decision"
    let body = rows.map { row in
      if row.audioOnly {
        return [
          row.fixture,
          "audio-only",
          "n/a",
          "n/a",
          "n/a",
          row.speakerPath,
          row.textGateDecision,
        ].joined(separator: ",")
      }
      return [
        row.fixture,
        Self.format(row.wer),
        Self.format(
          row.actualPilotDiscard && row.expectedPilotDiscard ? 1 : row.actualPilotDiscard ? 0 : 1),
        Self.format(row.expectedPilotDiscard ? (row.actualPilotDiscard ? 1 : 0) : 1),
        Self.format((row.actualPilotDiscard && !row.expectedPilotDiscard) ? 1 : 0),
        row.speakerPath,
        row.textGateDecision,
      ].joined(separator: ",")
    }
    let summary = [
      "SUMMARY",
      Self.format(averageWER),
      Self.format(pilotDiscardPrecision),
      Self.format(pilotDiscardRecall),
      Self.format(falseDiscardRate),
      "synthetic-amplitude-speaker-substitute",
      "real-voice-filter-text-gate",
    ].joined(separator: ",")
    return ([header] + body + [summary]).joined(separator: "\n")
  }

  private static func format(_ value: Double) -> String {
    String(format: "%.3f", value)
  }
}

struct ReplayEvaluator: Sendable {
  let audioReader: PCM16WAVAudioReader

  init(
    audioReader: PCM16WAVAudioReader = PCM16WAVAudioReader()
  ) {
    self.audioReader = audioReader
  }

  @MainActor
  func evaluate(fixturesDirectory: URL, manifest: ReplayManifest) async throws -> ReplayReport {
    let pipeline = Self.makePipeline()
    var rows: [ReplayMetrics] = []
    rows.reserveCapacity(manifest.fixtures.count)

    for (index, fixture) in manifest.fixtures.enumerated() {
      let audioURL = fixturesDirectory.appendingPathComponent(fixture.fixture)
      let audio = try audioReader.read(audioURL)
      let speaker = try await pipeline.classify(
        samples: audio.samples,
        sampleRate: audio.sampleRate
      )
      let decision = pipeline.decide(
        text: fixture.transcript,
        speaker: speaker,
        timestamp: Date(timeIntervalSince1970: Double(index)),
        localeIdentifier: fixture.locale
      )
      let actualTranscript = Self.filteredTranscript(
        fixture.transcript,
        decision: decision.relevance
      )
      let metric = ReplayMetrics(
        fixture: fixture.fixture,
        wer: fixture.isAudioOnly
          ? 0
          : WordErrorRate.score(
            reference: fixture.expectedTranscriptAfterFilter,
            hypothesis: actualTranscript
          ),
        expectedPilotDiscard: fixture.expectedPilotDiscard,
        actualPilotDiscard: actualTranscript.isEmpty && fixture.transcript.isEmpty == false,
        audioOnly: fixture.isAudioOnly,
        speakerPath: "synthetic-amplitude-speaker-substitute",
        textGateDecision: Self.describe(decision.relevance)
      )
      rows.append(metric)
    }

    return ReplayReport(rows: rows)
  }

  @MainActor
  private static func makePipeline() -> VoiceFilterPipeline {
    let profile = PilotVoiceProfile(
      label: "Replay Pilot",
      voicePrint: VoicePrintVector(values: [1, 0, 0, 0], quality: 0.95),
      enrolledAt: Date(timeIntervalSince1970: 748_137_600),
      spokenCallSign: CallSign(raw: "N123AB")
    )
    let storage = ReplayVoiceFilterStorage(
      profiles: [profile],
      callSign: CallSign(raw: "N123AB"),
      config: .default,
      enabled: true
    )
    return VoiceFilterPipeline(
      identifier: SyntheticReplaySpeakerIdentifier(),
      storage: storage,
      modelPackStorage: ReplayModelPackStorage(state: .installed(Self.installedPack()))
    )
  }

  private static func filteredTranscript(
    _ transcript: String,
    decision: ATCRelevanceDecision
  ) -> String {
    switch decision {
    case .display:
      return transcript
    case .suppress:
      return ""
    }
  }

  private static func describe(_ decision: ATCRelevanceDecision) -> String {
    switch decision {
    case .display(let reason):
      return "display-\(reason)"
    case .suppress(let reason):
      return "suppress-\(reason)"
    }
  }

  private static func installedPack() -> InstalledModelPack {
    InstalledModelPack(
      identifier: "synthetic-replay-speaker",
      version: "1.0.0",
      embeddingDimension: 4,
      checksumSHA256: String(repeating: "b", count: 64),
      source: "local-replay-fixture",
      sizeBytes: 4096,
      installedAt: Date(timeIntervalSince1970: 748_137_600),
      localModelPath: nil
    )
  }
}

enum WordErrorRate {
  static func score(reference: String, hypothesis: String) -> Double {
    let referenceTokens = tokenize(reference)
    let hypothesisTokens = tokenize(hypothesis)
    if referenceTokens.isEmpty {
      return hypothesisTokens.isEmpty ? 0 : 1
    }
    return Double(distance(referenceTokens, hypothesisTokens)) / Double(referenceTokens.count)
  }

  private static func tokenize(_ text: String) -> [String] {
    text
      .lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
  }

  private static func distance(_ a: [String], _ b: [String]) -> Int {
    var previous = Array(0...b.count)
    var current = Array(repeating: 0, count: b.count + 1)
    for i in 1...a.count {
      current[0] = i
      for j in 1...b.count {
        if a[i - 1] == b[j - 1] {
          current[j] = previous[j - 1]
        } else {
          current[j] = min(previous[j], current[j - 1], previous[j - 1]) + 1
        }
      }
      previous = current
    }
    return previous[b.count]
  }
}

struct ReplayArguments {
  let fixturesDirectory: URL
  let groundTruth: URL
  let thresholdSource: ThresholdSource

  enum ThresholdSource {
    case bundledDefault
    case explicit(URL)
  }

  static func parse(_ arguments: [String]) throws -> ReplayArguments {
    var fixturesDirectory: URL?
    var groundTruth: URL?
    var thresholdSource: ThresholdSource = .bundledDefault
    var index = 1
    while index < arguments.count {
      switch arguments[index] {
      case "--fixtures":
        index += 1
        guard index < arguments.count else {
          throw ReplayKitError.invalidArguments("Missing value for --fixtures")
        }
        fixturesDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
      case "--ground-truth":
        index += 1
        guard index < arguments.count else {
          throw ReplayKitError.invalidArguments("Missing value for --ground-truth")
        }
        groundTruth = URL(fileURLWithPath: arguments[index])
      case "--threshold":
        index += 1
        guard index < arguments.count else {
          throw ReplayKitError.invalidArguments("Missing value for --threshold")
        }
        thresholdSource = .explicit(URL(fileURLWithPath: arguments[index]))
      case "--help", "-h":
        throw ReplayKitError.invalidArguments(Self.usage)
      default:
        throw ReplayKitError.invalidArguments("Unknown argument: \(arguments[index])")
      }
      index += 1
    }
    guard let fixturesDirectory else {
      throw ReplayKitError.invalidArguments(Self.usage)
    }
    let resolvedGroundTruth =
      groundTruth ?? fixturesDirectory.appendingPathComponent("ground-truth.json")
    return ReplayArguments(
      fixturesDirectory: fixturesDirectory,
      groundTruth: resolvedGroundTruth,
      thresholdSource: thresholdSource
    )
  }

  private static let usage =
    "Usage: dspeech-replay --fixtures <directory> [--ground-truth <file>] [--threshold <file>]"
}

enum ThresholdLoader {
  static let bundledRelativePath = "Dspeech/Tools/ReplayKit/eval-threshold.json"

  static func load(source: ReplayArguments.ThresholdSource) throws -> ReplayThreshold {
    switch source {
    case .bundledDefault:
      if let bundledURL = locateBundled() {
        return try decode(bundledURL)
      }
      return .default
    case .explicit(let url):
      return try decode(url)
    }
  }

  private static func decode(_ url: URL) throws -> ReplayThreshold {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(ReplayThreshold.self, from: data)
  }

  // why: the binary may run from `swift run` (cwd = Dspeech/Tools/ReplayKit) or
  // from the repo root. Walk upwards from the executable directory and the cwd
  // until the bundled config is found; fall back to the in-binary default if
  // the file is not present (e.g. compiled binary copied outside the repo).
  private static func locateBundled() -> URL? {
    var roots: [URL] = []
    roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    roots.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
    let segments = bundledRelativePath.split(separator: "/").map(String.init)
    for root in roots {
      var cursor: URL? = root
      while let directory = cursor {
        let candidate = segments.reduce(directory) { acc, segment in
          acc.appendingPathComponent(segment)
        }
        if FileManager.default.fileExists(atPath: candidate.path) {
          return candidate
        }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { break }
        cursor = parent
      }
    }
    return nil
  }
}

@main
struct ReplayKitCommand {
  static func main() async {
    do {
      if CommandLine.arguments.dropFirst().first == "transcribe" {
        let status = try await TranscribeCommand.run(Array(CommandLine.arguments.dropFirst(2)))
        if status != 0 { exit(status) }
        return
      }
      let arguments = try ReplayArguments.parse(CommandLine.arguments)
      let data = try Data(contentsOf: arguments.groundTruth)
      let manifest = try JSONDecoder().decode(ReplayManifest.self, from: data)
      let threshold = try ThresholdLoader.load(source: arguments.thresholdSource)
      let report = try await ReplayEvaluator().evaluate(
        fixturesDirectory: arguments.fixturesDirectory,
        manifest: manifest
      )
      print(report.csv())
      let breaches = threshold.breaches(report)
      if !breaches.isEmpty {
        fputs("ReplayKit threshold breach:\n", stderr)
        for message in breaches {
          fputs("  - \(message)\n", stderr)
        }
        exit(2)
      }
    } catch {
      fputs("ReplayKit error: \(error)\n", stderr)
      exit(1)
    }
  }
}
