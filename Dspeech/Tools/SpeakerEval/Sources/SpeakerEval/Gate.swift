import FluidAudio
import Foundation

// Voice-separation gate eval — runs the REAL shipping decision path, not a re-implementation.
// For each FluidAudio-diarized segment of an (injection-augmented) chunk, it calls the vendored
// production FluidAudioSpeakerIdentifier.classify(samples:sampleRate:profiles:) — which runs
// SpeakerAudioPreprocessing.prepare (resample + RMS voicedQuality) + the minQuality gate +
// SpeakerMatcher.match(.default) exactly as on device. Ground truth is the AUTHORED injection
// window (we mixed a known operator voice in at [injectStart,injectEnd]); FluidAudio only
// ENUMERATES candidate segments — it never grades itself. Plus 3 deterministic void controls.
//
//   swift run SpeakerEval gate <enroll.wav> <chunk.wav> <injectStart> <injectEnd>
// Emits a single JSON object on stdout (the orchestrator asserts on it).

private func fluidModelDir() -> URL {
  FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/FluidAudio/Models/speaker-diarization")
}

private func describe(_ decision: SpeakerMatchDecision) -> (kind: String, score: Double) {
  switch decision {
  case .pilot(let score): return ("pilot", Double(score))
  case .nonPilot(let best): return ("nonPilot", Double(best))
  case .mixed(let best): return ("mixed", Double(best))
  case .insufficientSpeech: return ("insufficientSpeech", 0)
  }
}

private func sineTone(seconds: Double, hz: Double, amplitude: Float) -> [Float] {
  let n = Int(seconds * 16000)
  return (0..<n).map { amplitude * Float(sin(2.0 * Double.pi * hz * Double($0) / 16000.0)) }
}

func runGate(
  enrollURL: URL, chunkURL: URL, injectStart: Double, injectEnd: Double, manager: DiarizerManager
) async throws {
  let dir = fluidModelDir()
  let identifier = FluidAudioSpeakerIdentifier(
    segmentationModelURL: dir.appendingPathComponent("pyannote_segmentation.mlmodelc"),
    embeddingModelURL: dir.appendingPathComponent("wespeaker_v2.mlmodelc")
  )

  var out: [String: Any] = [
    "enroll": enrollURL.lastPathComponent,
    "chunk": chunkURL.lastPathComponent,
    "injectWindow": [injectStart, injectEnd],
  ]

  // Enrol the operator (real shipping enroll() — prepare + RMS quality + minQuality gate).
  let enrollSamples = try readMono16k(enrollURL)
  let profile: PilotVoiceProfile
  do {
    let vp = try await identifier.enroll(samples: enrollSamples, sampleRate: 16000)
    profile = PilotVoiceProfile(label: "test-pilot", voicePrint: vp)
    out["enrollQuality"] = Double(SpeakerAudioPreprocessing.voicedQuality(enrollSamples))
  } catch {
    out["enrollError"] = "\(error)"
    print(jsonString(out))
    return
  }

  // Per-segment REAL classify on the chunk's own window audio.
  let chunkSamples = try readMono16k(chunkURL)
  let diar = try manager.performCompleteDiarization(chunkSamples, sampleRate: 16000)
  var segments: [[String: Any]] = []
  for seg in diar.segments {
    let s = max(0, Int(Double(seg.startTimeSeconds) * 16000))
    let e = min(chunkSamples.count, Int(Double(seg.endTimeSeconds) * 16000))
    guard e > s else { continue }
    let slice = Array(chunkSamples[s..<e])
    let appQuality = SpeakerAudioPreprocessing.voicedQuality(slice)
    let decision = try await identifier.classify(
      samples: slice, sampleRate: 16000, profiles: [profile])
    let (kind, score) = describe(decision)
    // overlap of this segment with the AUTHORED injection window (the only ground truth)
    let segStart = Double(seg.startTimeSeconds)
    let segEnd = Double(seg.endTimeSeconds)
    let inWindow = segStart < injectEnd && segEnd > injectStart
    segments.append([
      "start": segStart, "end": segEnd, "decision": kind, "score": score,
      "appQuality": Double(appQuality), "inInjectedWindow": inWindow,
    ])
  }
  out["segments"] = segments

  // Void controls — any wrong answer must VOID the run (a constant/short-circuited matcher
  // cannot satisfy all three): own enrolment -> pilot; true silence -> insufficientSpeech;
  // loud NON-voice tone (high RMS, clears minQuality) -> must NOT be pilot.
  let own = describe(
    try await identifier.classify(samples: enrollSamples, sampleRate: 16000, profiles: [profile]))
  let silence = describe(
    try await identifier.classify(
      samples: [Float](repeating: 0, count: 16000), sampleRate: 16000, profiles: [profile]))
  let tone = sineTone(seconds: 1.0, hz: 440, amplitude: 0.5)
  let toneDecision = describe(
    try await identifier.classify(samples: tone, sampleRate: 16000, profiles: [profile]))
  out["voidControls"] = [
    "ownEmbedding": own.kind, "silence": silence.kind, "loudNonVoice": toneDecision.kind,
    "toneQuality": Double(SpeakerAudioPreprocessing.voicedQuality(tone)),
  ]

  print(jsonString(out))
}

func jsonString(_ object: [String: Any]) -> String {
  guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
    let string = String(data: data, encoding: .utf8)
  else { return "{}" }
  return string
}
