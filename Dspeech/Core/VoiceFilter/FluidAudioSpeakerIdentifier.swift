import FluidAudio
import Foundation

enum SpeakerAudioPreprocessing {
  static let targetSampleRate: Double = 16_000
  static let minVoicedQuality: Float = SpeakerMatchConfig.default.minQuality

  struct Prepared: Equatable, Sendable {
    let samples: [Float]
    let quality: Float
  }

  static func prepare(samples: [Float], sampleRate: Double) -> Prepared {
    let resampled = resample(samples, from: sampleRate, to: targetSampleRate)
    return Prepared(samples: resampled, quality: voicedQuality(resampled))
  }

  static func resample(_ samples: [Float], from input: Double, to output: Double) -> [Float] {
    guard samples.count > 1, input > 0, output > 0 else { return samples }
    guard abs(input - output) >= 0.5 else { return samples }
    let ratio = output / input
    let outputCount = max(1, Int((Double(samples.count) * ratio).rounded()))
    var result = [Float](repeating: 0, count: outputCount)
    let lastIndex = samples.count - 1
    for i in 0..<outputCount {
      let sourcePosition = Double(i) / ratio
      let lower = min(Int(sourcePosition.rounded(.down)), lastIndex)
      let upper = min(lower + 1, lastIndex)
      let fraction = Float(sourcePosition - Double(lower))
      result[i] = samples[lower] * (1 - fraction) + samples[upper] * fraction
    }
    return result
  }

  static func voicedQuality(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sumSquares: Double = 0
    for sample in samples {
      sumSquares += Double(sample) * Double(sample)
    }
    let rootMeanSquare = (sumSquares / Double(samples.count)).squareRoot()
    return Float(min(1.0, max(0.0, rootMeanSquare * 4.0)))
  }
}

actor FluidAudioDiarizerHandle {
  private let segmentationModelURL: URL
  private let embeddingModelURL: URL
  private var diarizer: DiarizerManager?

  init(segmentationModelURL: URL, embeddingModelURL: URL) {
    self.segmentationModelURL = segmentationModelURL
    self.embeddingModelURL = embeddingModelURL
  }

  func extractEmbedding(from samples: [Float]) async throws -> [Float] {
    let manager = try await loadedDiarizer()
    return try manager.extractSpeakerEmbedding(from: samples)
  }

  private func loadedDiarizer() async throws -> DiarizerManager {
    if let diarizer {
      DspeechLog.modelPack.debug("fluid audio diarizer reused")
      return diarizer
    }
    DspeechLog.modelPack.info("fluid audio diarizer load requested")
    do {
      let models = try DiarizerModels.load(
        localSegmentationModel: segmentationModelURL,
        localEmbeddingModel: embeddingModelURL
      )
      let manager = DiarizerManager()
      manager.initialize(models: models)
      diarizer = manager
      DspeechLog.modelPack.info("fluid audio diarizer load succeeded")
      return manager
    } catch {
      DspeechLog.modelPack.error(
        "fluid audio diarizer load failed error=\(error.localizedDescription)"
      )
      throw error
    }
  }
}

struct FluidAudioSpeakerIdentifier: LocalSpeakerIdentifier {
  static let weSpeakerEmbeddingDimension = 256

  let embeddingDimension = FluidAudioSpeakerIdentifier.weSpeakerEmbeddingDimension
  let availability: LocalSpeakerIdentifierAvailability = .available

  private let handle: FluidAudioDiarizerHandle
  private let matchConfig: SpeakerMatchConfig

  init(
    segmentationModelURL: URL,
    embeddingModelURL: URL,
    matchConfig: SpeakerMatchConfig = .default
  ) {
    self.handle = FluidAudioDiarizerHandle(
      segmentationModelURL: segmentationModelURL,
      embeddingModelURL: embeddingModelURL
    )
    self.matchConfig = matchConfig
  }

  func enroll(samples: [Float], sampleRate: Double) async throws -> VoicePrintVector {
    DspeechLog.modelPack.info(
      "fluid audio enrollment requested samples=\(samples.count, privacy: .public) sampleRate=\(sampleRate, privacy: .public)"
    )
    // why: NO quality gate on ENROLLMENT. The recorder already requires real voiced speech, and the
    // minVoicedQuality 0.25 floor is calibrated to reject noisy RECEIVED ATC for CLASSIFICATION — it
    // wrongly rejected a perfectly good own-voice recording made a touch quietly (2026-06-14 device
    // report). The WeSpeaker embedding is the real arbiter; a weak sample just separates less well and
    // the user can re-record. Classification keeps the gate.
    let prepared = SpeakerAudioPreprocessing.prepare(samples: samples, sampleRate: sampleRate)
    let embedding = try await embedding(for: prepared.samples)
    DspeechLog.modelPack.info(
      "fluid audio enrollment succeeded embeddingDimension=\(embedding.count, privacy: .public)"
    )
    return try VoicePrintVector(validatingValues: embedding, quality: prepared.quality)
  }

  func classify(
    samples: [Float],
    sampleRate: Double,
    profiles: [PilotVoiceProfile]
  ) async throws -> SpeakerMatchDecision {
    let prepared = SpeakerAudioPreprocessing.prepare(samples: samples, sampleRate: sampleRate)
    guard prepared.quality >= SpeakerAudioPreprocessing.minVoicedQuality else {
      DspeechLog.modelPack.debug("fluid audio classification skipped reason=insufficient-speech")
      return .insufficientSpeech
    }
    let embedding = try await embedding(for: prepared.samples)
    let candidate = try VoicePrintVector(validatingValues: embedding, quality: prepared.quality)
    let decision = SpeakerMatcher.match(
      candidate: candidate,
      profiles: profiles,
      config: matchConfig
    )
    DspeechLog.modelPack.debug(
      "fluid audio classification succeeded decision=\(decision.logName, privacy: .public)"
    )
    return decision
  }

  private func embedding(for samples: [Float]) async throws -> [Float] {
    let embedding: [Float]
    do {
      embedding = try await handle.extractEmbedding(from: samples)
    } catch {
      DspeechLog.modelPack.error(
        "fluid audio embedding failed reason=model-load-or-apply error=\(error.localizedDescription)"
      )
      throw LocalSpeakerIdentifierError.modelUnavailable(
        reason:
          String(
            localized: "Couldn't load or apply the local FluidAudio model from the installed pack.")
      )
    }
    guard embedding.count == embeddingDimension else {
      DspeechLog.modelPack.error(
        "fluid audio embedding failed reason=dimension-mismatch expected=\(embeddingDimension, privacy: .public) got=\(embedding.count, privacy: .public)"
      )
      throw LocalSpeakerIdentifierError.incompatibleDimension(
        expected: embeddingDimension,
        got: embedding.count
      )
    }
    return embedding
  }
}

struct FluidAudioBackendBuilder: LocalSpeakerBackendBuilder {
  static let segmentationModelFileName = "pyannote_segmentation.mlmodelc"
  static let embeddingModelFileName = "wespeaker_v2.mlmodelc"

  private let fileExists: @Sendable (String) -> Bool
  private let matchConfig: SpeakerMatchConfig

  init(
    matchConfig: SpeakerMatchConfig = .default,
    fileExists: @escaping @Sendable (String) -> Bool = {
      FileManager.default.fileExists(atPath: $0)
    }
  ) {
    self.matchConfig = matchConfig
    self.fileExists = fileExists
  }

  func makeIdentifier(for pack: InstalledModelPack) throws -> any LocalSpeakerIdentifier {
    DspeechLog.modelPack.info(
      "fluid audio identifier build requested identifier=\(pack.identifier, privacy: .public) version=\(pack.version, privacy: .public)"
    )
    guard let localModelPath = pack.localModelPath, !localModelPath.isEmpty else {
      DspeechLog.modelPack.error("fluid audio identifier build failed reason=missing-local-path")
      throw LocalSpeakerIdentifierError.modelUnavailable(
        reason: String(localized: "The installed pack contains no local model path.")
      )
    }
    let base = URL(fileURLWithPath: localModelPath, isDirectory: true)
    let segmentationModelURL = base.appendingPathComponent(Self.segmentationModelFileName)
    let embeddingModelURL = base.appendingPathComponent(Self.embeddingModelFileName)
    guard fileExists(segmentationModelURL.path), fileExists(embeddingModelURL.path) else {
      DspeechLog.modelPack.error("fluid audio identifier build failed reason=model-files-missing")
      throw LocalSpeakerIdentifierError.modelUnavailable(
        reason: String(
          localized: "The local FluidAudio model files are missing from the installed pack.")
      )
    }
    let identifier = FluidAudioSpeakerIdentifier(
      segmentationModelURL: segmentationModelURL,
      embeddingModelURL: embeddingModelURL,
      matchConfig: matchConfig
    )
    DspeechLog.modelPack.info(
      "fluid audio identifier build succeeded embeddingDimension=\(FluidAudioSpeakerIdentifier.weSpeakerEmbeddingDimension, privacy: .public)"
    )
    return identifier
  }
}
