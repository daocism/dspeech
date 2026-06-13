import AVFoundation
import FluidAudio
import Foundation

// Host evaluation: run the real FluidAudio diarizer + WeSpeaker embedding model over
// recorded ATC fixtures and report distinct speakers, segment timings, 256-dim
// embeddings, and cross-clip / enroll→classify cosine distances. Usage:
//   swift run SpeakerEval <wav> [<wav> ...]
// With no args, defaults to the committed real-ATC fixtures.

func readMono16k(_ url: URL) throws -> [Float] {
  let file = try AVAudioFile(forReading: url)
  let format = file.processingFormat
  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
  try file.read(into: buffer)
  let frames = Int(buffer.frameLength)
  let channels = Int(format.channelCount)
  let data = buffer.floatChannelData!
  var mono = [Float](repeating: 0, count: frames)
  for frame in 0..<frames {
    var sum: Float = 0
    for channel in 0..<channels { sum += data[channel][frame] }
    mono[frame] = sum / Float(channels)
  }
  return mono
}

func fmt(_ value: Float) -> String { String(format: "%.3f", value) }

func defaultFixtures() -> [URL] {
  // why: locate the committed fixtures relative to the package, so the eval is
  // self-contained from a repo checkout regardless of the working directory.
  let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Sources/SpeakerEval
    .deletingLastPathComponent()  // Sources
    .deletingLastPathComponent()  // SpeakerEval (package)
    .deletingLastPathComponent()  // Tools
    .deletingLastPathComponent()  // Dspeech
    .deletingLastPathComponent()  // repo root
  let fixtures = repoRoot.appendingPathComponent("DspeechTests/Fixtures/ReplayKit")
  return ["atc-real-img2549.wav", "atc-real-img2551.wav"].map {
    fixtures.appendingPathComponent($0)
  }
}

let argumentPaths = Array(CommandLine.arguments.dropFirst())
let inputs: [URL] =
  argumentPaths.isEmpty ? defaultFixtures() : argumentPaths.map { URL(fileURLWithPath: $0) }

print("Loading FluidAudio diarizer models (pyannote_segmentation + wespeaker_v2)…")
let models = try await DiarizerModels.download()
let manager = DiarizerManager()
manager.initialize(models: models)
print("Models ready.\n" + String(repeating: "─", count: 64))

// Calibration mode: `swift run SpeakerEval calibrate <corpus-dir> <voice-corpus.json>`
if argumentPaths.first == "calibrate", argumentPaths.count >= 3 {
  try runCalibration(
    corpusDirectory: URL(fileURLWithPath: argumentPaths[1], isDirectory: true),
    manifestPath: URL(fileURLWithPath: argumentPaths[2]),
    manager: manager
  )
  exit(0)
}

// Voice-separation gate mode (runs the REAL shipping classify path):
// `swift run SpeakerEval gate <enroll.wav> <chunk.wav> <injectStart> <injectEnd>`
if argumentPaths.first == "gate", argumentPaths.count >= 5 {
  try await runGate(
    enrollURL: URL(fileURLWithPath: argumentPaths[1]),
    chunkURL: URL(fileURLWithPath: argumentPaths[2]),
    injectStart: Double(argumentPaths[3]) ?? 0,
    injectEnd: Double(argumentPaths[4]) ?? 0,
    manager: manager
  )
  exit(0)
}

var wholeClipEmbeddings: [(String, [Float])] = []
var firstSegmentEmbedding: (clip: String, speaker: String, vector: [Float])?

for url in inputs {
  let name = url.lastPathComponent
  let samples = try readMono16k(url)
  let seconds = Float(samples.count) / 16000.0
  print("### \(name) — \(fmt(seconds))s, \(samples.count) samples @16kHz")

  let result = try manager.performCompleteDiarization(samples, sampleRate: 16000)
  let speakers = Set(result.segments.map(\.speakerId)).sorted()
  print(
    "    diarization: \(speakers.count) distinct speaker(s), \(result.segments.count) segment(s)")
  for segment in result.segments {
    print(
      "      [\(fmt(segment.startTimeSeconds))s–\(fmt(segment.endTimeSeconds))s] "
        + "speaker=\(segment.speakerId) quality=\(fmt(segment.qualityScore)) "
        + "embDim=\(segment.embedding.count)")
    if firstSegmentEmbedding == nil, !segment.embedding.isEmpty {
      firstSegmentEmbedding = (name, segment.speakerId, segment.embedding)
    }
  }

  if result.segments.count >= 2 {
    for i in 0..<result.segments.count {
      for j in (i + 1)..<result.segments.count {
        let a = result.segments[i]
        let b = result.segments[j]
        guard !a.embedding.isEmpty, !b.embedding.isEmpty else { continue }
        let distance = SpeakerUtilities.cosineDistance(a.embedding, b.embedding)
        let relation = a.speakerId == b.speakerId ? "same-speaker" : "cross-speaker"
        print("      Δ seg\(i)↔seg\(j) (\(relation)): cosineDistance=\(fmt(distance))")
      }
    }
  }

  let wholeEmbedding = try manager.extractSpeakerEmbedding(from: samples)
  print("    whole-clip speaker embedding: dim=\(wholeEmbedding.count)")
  wholeClipEmbeddings.append((name, wholeEmbedding))
  print("")
}

print(String(repeating: "─", count: 64))
if wholeClipEmbeddings.count == 2 {
  let distance = SpeakerUtilities.cosineDistance(
    wholeClipEmbeddings[0].1, wholeClipEmbeddings[1].1)
  print(
    "Cross-clip whole-embedding cosineDistance "
      + "(\(wholeClipEmbeddings[0].0) ↔ \(wholeClipEmbeddings[1].0)): "
      + "\(fmt(distance)) (0=identical voice, 2=opposite)")
}

if let enrolled = firstSegmentEmbedding {
  print("\nEnroll→classify demo — enrolled speaker=\(enrolled.speaker) from \(enrolled.clip):")
  for (name, embedding) in wholeClipEmbeddings {
    let distance = SpeakerUtilities.cosineDistance(enrolled.vector, embedding)
    let similarity = 1.0 - distance / 2.0
    print("    vs \(name): cosineDistance=\(fmt(distance)) similarity≈\(fmt(similarity))")
  }
}
