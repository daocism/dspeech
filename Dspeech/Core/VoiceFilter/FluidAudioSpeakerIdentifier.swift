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
      return diarizer
    }
    let models = try DiarizerModels.load(
      localSegmentationModel: segmentationModelURL,
      localEmbeddingModel: embeddingModelURL
    )
    let manager = DiarizerManager()
    manager.initialize(models: models)
    diarizer = manager
    return manager
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
    let prepared = SpeakerAudioPreprocessing.prepare(samples: samples, sampleRate: sampleRate)
    guard prepared.quality >= SpeakerAudioPreprocessing.minVoicedQuality else {
      throw LocalSpeakerIdentifierError.insufficientSpeech
    }
    let embedding = try await embedding(for: prepared.samples)
    return VoicePrintVector(values: embedding, quality: prepared.quality)
  }

  func classify(
    samples: [Float],
    sampleRate: Double,
    profiles: [PilotVoiceProfile]
  ) async throws -> SpeakerMatchDecision {
    let prepared = SpeakerAudioPreprocessing.prepare(samples: samples, sampleRate: sampleRate)
    guard prepared.quality >= SpeakerAudioPreprocessing.minVoicedQuality else {
      return .insufficientSpeech
    }
    let embedding = try await embedding(for: prepared.samples)
    let candidate = VoicePrintVector(values: embedding, quality: prepared.quality)
    return SpeakerMatcher.match(candidate: candidate, profiles: profiles, config: matchConfig)
  }

  private func embedding(for samples: [Float]) async throws -> [Float] {
    let embedding: [Float]
    do {
      embedding = try await handle.extractEmbedding(from: samples)
    } catch {
      throw LocalSpeakerIdentifierError.modelUnavailable(
        reason:
          "Не удалось загрузить или применить локальную модель FluidAudio из установленного пакета."
      )
    }
    guard embedding.count == embeddingDimension else {
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
    guard let localModelPath = pack.localModelPath, !localModelPath.isEmpty else {
      throw LocalSpeakerIdentifierError.modelUnavailable(
        reason: "Установленный пакет не содержит локального пути к модели."
      )
    }
    let base = URL(fileURLWithPath: localModelPath, isDirectory: true)
    let segmentationModelURL = base.appendingPathComponent(Self.segmentationModelFileName)
    let embeddingModelURL = base.appendingPathComponent(Self.embeddingModelFileName)
    guard fileExists(segmentationModelURL.path), fileExists(embeddingModelURL.path) else {
      throw LocalSpeakerIdentifierError.modelUnavailable(
        reason: "Файлы локальной модели FluidAudio отсутствуют в установленном пакете."
      )
    }
    return FluidAudioSpeakerIdentifier(
      segmentationModelURL: segmentationModelURL,
      embeddingModelURL: embeddingModelURL,
      matchConfig: matchConfig
    )
  }
}
