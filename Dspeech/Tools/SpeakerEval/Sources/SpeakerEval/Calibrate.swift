import FluidAudio
import Foundation

// Calibration mode: run the REAL FluidAudio WeSpeaker embedding over a labeled single-voice
// corpus (the controlled TTS clips), then measure same-voice vs cross-voice cosine SIMILARITY
// to choose SpeakerMatchConfig thresholds from real numbers instead of guesses.
//
// Metric note: SpeakerMatcher uses raw cosine similarity (dot / |a||b|). FluidAudio reports
// cosineDistance with 0=identical, 2=opposite, i.e. distance = 1 - cosine, so the value the
// app compares against is `1 - SpeakerUtilities.cosineDistance(a, b)`.
//
//   swift run SpeakerEval calibrate <corpus-dir> <voice-corpus.json>

struct CalibrationClip: Decodable {
  let id: String
  let voice: String
}

struct CalibrationThresholds: Decodable {
  let sameVoiceMinCosine: Float?
  let crossVoiceMaxCosine: Float?
}

struct CalibrationManifest: Decodable {
  let clips: [CalibrationClip]
  let thresholds: CalibrationThresholds?
}

enum CalibrationError: Error, CustomStringConvertible {
  case separationRegressed(String)
  var description: String {
    switch self {
    case .separationRegressed(let message): return message
    }
  }
}

func appCosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
  1.0 - SpeakerUtilities.cosineDistance(a, b)
}

private func stats(_ values: [Float]) -> (min: Float, mean: Float, max: Float) {
  guard !values.isEmpty else { return (0, 0, 0) }
  return (values.min()!, values.reduce(0, +) / Float(values.count), values.max()!)
}

func runCalibration(corpusDirectory: URL, manifestPath: URL, manager: DiarizerManager) throws {
  let manifest = try JSONDecoder().decode(
    CalibrationManifest.self, from: try Data(contentsOf: manifestPath))

  var embeddings: [(id: String, voice: String, vector: [Float])] = []
  for clip in manifest.clips {
    let url = corpusDirectory.appendingPathComponent("\(clip.id).wav")
    guard FileManager.default.fileExists(atPath: url.path) else {
      print("  skip \(clip.id): no wav (run generate-voice-corpus.sh)")
      continue
    }
    let samples = try readMono16k(url)
    let vector = try manager.extractSpeakerEmbedding(from: samples)
    guard !vector.isEmpty else {
      print("  skip \(clip.id): empty embedding")
      continue
    }
    embeddings.append((clip.id, clip.voice, vector))
  }

  var same: [Float] = []
  var cross: [Float] = []
  for i in 0..<embeddings.count {
    for j in (i + 1)..<embeddings.count {
      let similarity = appCosineSimilarity(embeddings[i].vector, embeddings[j].vector)
      if embeddings[i].voice == embeddings[j].voice {
        same.append(similarity)
      } else {
        cross.append(similarity)
      }
    }
  }

  let voices = Set(embeddings.map(\.voice)).sorted()
  let sameStats = stats(same)
  let crossStats = stats(cross)
  print(String(repeating: "─", count: 64))
  print(
    "CALIBRATION  clips=\(embeddings.count) voices=\(voices) "
      + "same-pairs=\(same.count) cross-pairs=\(cross.count)")
  print(
    String(
      format: "  SAME-voice  cosine: min=%.3f mean=%.3f max=%.3f",
      sameStats.min, sameStats.mean, sameStats.max))
  print(
    String(
      format: "  CROSS-voice cosine: min=%.3f mean=%.3f max=%.3f",
      crossStats.min, crossStats.mean, crossStats.max))

  let separable = sameStats.min > crossStats.max
  // pilotMatchThreshold: must sit ABOVE the highest cross-voice score (never call another
  // speaker the pilot) and at/below the lowest same-voice score (always catch the pilot).
  let pilotMatch = separable ? (sameStats.min + crossStats.max) / 2 : crossStats.max
  // mixedSpeakerLowerBound: below this is clearly a different speaker.
  let mixedLower = (crossStats.mean + crossStats.max) / 2
  let separationMargin = max(0, sameStats.min - crossStats.max) / 2
  print(
    String(
      format: "  RECOMMEND  pilotMatchThreshold≈%.3f  mixedSpeakerLowerBound≈%.3f  "
        + "separationMargin≈%.3f", pilotMatch, mixedLower, separationMargin))
  print("  separable: \(separable ? "YES (clean gap)" : "NO — overlap; threshold trades FP/FN")")

  // Regression guard: the safety thresholds (SpeakerMatchConfig pilotMatch 0.72,
  // ATCTranscriptGate pilotSuppress 0.82) are only valid while the real model keeps SAME-voice
  // well ABOVE and CROSS-voice well BELOW the gap that brackets them. If a FluidAudio/extraction
  // change collapses that separation, FAIL loudly so the thresholds get re-derived instead of
  // silently mis-classifying crew vs dispatcher. Bounds live in the corpus manifest.
  // Reach floor (anti-vacuity): a guard that measured too few pairs proves nothing — e.g. a degenerate
  // single-voice corpus where cross == [] makes crossStats.max == 0 and `separable` trivially true.
  // Require real same- AND cross-voice evidence before the guard can mean anything. ("measure reach".)
  let minSamePairs = 3
  let minCrossPairs = 3
  guard same.count >= minSamePairs, cross.count >= minCrossPairs else {
    throw CalibrationError.separationRegressed(
      "insufficient pairs to measure separation: same=\(same.count) cross=\(cross.count) "
        + "(need ≥\(minSamePairs) same and ≥\(minCrossPairs) cross — corpus is degenerate)")
  }
  // Bounds are REQUIRED, not optional: a manifest without cosine bounds must fail loudly, never
  // silently skip the regression guard.
  guard let minSame = manifest.thresholds?.sameVoiceMinCosine,
    let maxCross = manifest.thresholds?.crossVoiceMaxCosine
  else {
    throw CalibrationError.separationRegressed(
      "manifest missing sameVoiceMinCosine / crossVoiceMaxCosine bounds — cannot guard separation")
  }
  var failures: [String] = []
  if sameStats.min < minSame {
    failures.append("SAME-voice min \(sameStats.min) < required \(minSame)")
  }
  if crossStats.max > maxCross {
    failures.append("CROSS-voice max \(crossStats.max) > allowed \(maxCross)")
  }
  if !separable {
    failures.append("no clean gap: SAME-min \(sameStats.min) <= CROSS-max \(crossStats.max)")
  }
  guard failures.isEmpty else {
    throw CalibrationError.separationRegressed(
      "speaker separation regressed: " + failures.joined(separator: "; "))
  }
  print("  GUARD: PASS — real-model separation holds the calibrated thresholds")
}
