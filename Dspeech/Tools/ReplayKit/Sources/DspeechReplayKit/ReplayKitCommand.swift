import Foundation

enum ReplayKitError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case invalidFixture(String)
    case missingFixture(String)

    var description: String {
        switch self {
        case .invalidArguments(let message): message
        case .invalidFixture(let message): message
        case .missingFixture(let message): message
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
              String(bytes: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw ReplayKitError.invalidFixture("Fixture is not a RIFF/WAVE file: \(url.lastPathComponent)")
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
                    throw ReplayKitError.invalidFixture("WAV fmt chunk is incomplete: \(url.lastPathComponent)")
                }
                let audioFormat = Self.readUInt16LE(data, offset: chunkStart)
                guard audioFormat == 1 else {
                    throw ReplayKitError.invalidFixture("Only PCM WAV fixtures are supported: \(url.lastPathComponent)")
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
            throw ReplayKitError.invalidFixture("WAV fixture is missing fmt or data chunk: \(url.lastPathComponent)")
        }
        guard channelCount > 0 else {
            throw ReplayKitError.invalidFixture("WAV fixture has no channels: \(url.lastPathComponent)")
        }
        guard bitsPerSample == 16 else {
            throw ReplayKitError.invalidFixture("Only 16-bit PCM WAV fixtures are supported: \(url.lastPathComponent)")
        }

        let bytesPerFrame = Int(channelCount) * 2
        guard pcmData.count >= bytesPerFrame, pcmData.count % bytesPerFrame == 0 else {
            throw ReplayKitError.invalidFixture("WAV data chunk has invalid frame alignment: \(url.lastPathComponent)")
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

enum SyntheticSpeakerDecision: Sendable {
    case pilot
    case nonPilot
    case mixed
    case insufficientSpeech
}

struct SyntheticReplayFilter: Sendable {
    let callSign = "n123ab"

    func classify(audio: SourceAudio) -> SyntheticSpeakerDecision {
        guard !audio.samples.isEmpty else { return .insufficientSpeech }
        let averageMagnitude = audio.samples.reduce(Float(0)) { $0 + abs($1) } / Float(audio.samples.count)
        if averageMagnitude >= 0.80 {
            return .pilot
        }
        if averageMagnitude >= 0.55 {
            return .mixed
        }
        return .nonPilot
    }

    func filteredTranscript(_ transcript: String, speaker: SyntheticSpeakerDecision) -> String {
        switch speaker {
        case .pilot, .insufficientSpeech:
            return ""
        case .mixed, .nonPilot:
            return transcript.lowercased().contains(callSign) ? transcript : ""
        }
    }
}

struct ReplayMetrics: Sendable {
    let fixture: String
    let wer: Double
    let expectedPilotDiscard: Bool
    let actualPilotDiscard: Bool
}

struct ReplayReport: Sendable {
    let rows: [ReplayMetrics]

    var averageWER: Double {
        guard !rows.isEmpty else { return 0 }
        return rows.map(\.wer).reduce(0, +) / Double(rows.count)
    }

    var pilotDiscardPrecision: Double {
        let actual = rows.filter(\.actualPilotDiscard)
        guard !actual.isEmpty else { return 1 }
        let correct = actual.filter(\.expectedPilotDiscard).count
        return Double(correct) / Double(actual.count)
    }

    var pilotDiscardRecall: Double {
        let expected = rows.filter(\.expectedPilotDiscard)
        guard !expected.isEmpty else { return 1 }
        let correct = expected.filter(\.actualPilotDiscard).count
        return Double(correct) / Double(expected.count)
    }

    var falseDiscardRate: Double {
        let expectedKept = rows.filter { !$0.expectedPilotDiscard }
        guard !expectedKept.isEmpty else { return 0 }
        let falseDiscards = expectedKept.filter(\.actualPilotDiscard).count
        return Double(falseDiscards) / Double(expectedKept.count)
    }

    func csv() -> String {
        let header = "fixture,WER,pilot-discard-precision,pilot-discard-recall,false-discard-rate"
        let body = rows.map { row in
            [
                row.fixture,
                Self.format(row.wer),
                Self.format(row.actualPilotDiscard && row.expectedPilotDiscard ? 1 : row.actualPilotDiscard ? 0 : 1),
                Self.format(row.expectedPilotDiscard ? (row.actualPilotDiscard ? 1 : 0) : 1),
                Self.format((row.actualPilotDiscard && !row.expectedPilotDiscard) ? 1 : 0)
            ].joined(separator: ",")
        }
        let summary = [
            "SUMMARY",
            Self.format(averageWER),
            Self.format(pilotDiscardPrecision),
            Self.format(pilotDiscardRecall),
            Self.format(falseDiscardRate)
        ].joined(separator: ",")
        return ([header] + body + [summary]).joined(separator: "\n")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

struct ReplayEvaluator: Sendable {
    let audioReader: PCM16WAVAudioReader
    let filter: SyntheticReplayFilter

    init(
        audioReader: PCM16WAVAudioReader = PCM16WAVAudioReader(),
        filter: SyntheticReplayFilter = SyntheticReplayFilter()
    ) {
        self.audioReader = audioReader
        self.filter = filter
    }

    func evaluate(fixturesDirectory: URL, manifest: ReplayManifest) throws -> ReplayReport {
        var rows: [ReplayMetrics] = []
        rows.reserveCapacity(manifest.fixtures.count)

        for fixture in manifest.fixtures {
            let audioURL = fixturesDirectory.appendingPathComponent(fixture.fixture)
            let audio = try audioReader.read(audioURL)
            let speaker = filter.classify(audio: audio)
            let actualTranscript = filter.filteredTranscript(fixture.transcript, speaker: speaker)
            rows.append(
                ReplayMetrics(
                    fixture: fixture.fixture,
                    wer: WordErrorRate.score(
                        reference: fixture.expectedTranscriptAfterFilter,
                        hypothesis: actualTranscript
                    ),
                    expectedPilotDiscard: fixture.expectedPilotDiscard,
                    actualPilotDiscard: actualTranscript.isEmpty && fixture.transcript.isEmpty == false
                )
            )
        }

        return ReplayReport(rows: rows)
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

    static func parse(_ arguments: [String]) throws -> ReplayArguments {
        var fixturesDirectory: URL?
        var groundTruth: URL?
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
        let resolvedGroundTruth = groundTruth ?? fixturesDirectory.appendingPathComponent("ground-truth.json")
        return ReplayArguments(fixturesDirectory: fixturesDirectory, groundTruth: resolvedGroundTruth)
    }

    private static let usage = "Usage: dspeech-replay --fixtures <directory> [--ground-truth <file>]"
}

@main
struct ReplayKitCommand {
    static func main() {
        do {
            let arguments = try ReplayArguments.parse(CommandLine.arguments)
            let data = try Data(contentsOf: arguments.groundTruth)
            let manifest = try JSONDecoder().decode(ReplayManifest.self, from: data)
            let report = try ReplayEvaluator().evaluate(
                fixturesDirectory: arguments.fixturesDirectory,
                manifest: manifest
            )
            print(report.csv())
        } catch {
            fputs("ReplayKit error: \(error)\n", stderr)
            exit(1)
        }
    }
}
