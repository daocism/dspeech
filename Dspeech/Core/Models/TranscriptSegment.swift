import Foundation

struct TranscriptSegment: Identifiable, Equatable, Sendable, Codable {
  enum Source: String, Sendable {
    case liveATC
    case replay
    case demo
  }

  enum CodingKeys: String, CodingKey {
    case id
    case startedAt
    case text
    case translatedText
    case confidence
    case sourceLanguageCode
    case source
    case isStopCommittedPlaceholder
    case isInterimRestartCommit
  }

  let id: UUID
  let startedAt: Date
  let text: String
  let translatedText: String?
  let confidence: Double
  let sourceLanguageCode: String
  let source: Source
  let isStopCommittedPlaceholder: Bool
  let isInterimRestartCommit: Bool

  init(
    id: UUID = UUID(),
    startedAt: Date = .now,
    text: String,
    translatedText: String? = nil,
    confidence: Double,
    sourceLanguageCode: String,
    source: Source,
    isStopCommittedPlaceholder: Bool = false,
    isInterimRestartCommit: Bool = false
  ) {
    self.id = id
    self.startedAt = startedAt
    self.text = text
    self.translatedText = translatedText
    self.confidence = confidence
    self.sourceLanguageCode = sourceLanguageCode
    self.source = source
    self.isStopCommittedPlaceholder = isStopCommittedPlaceholder
    self.isInterimRestartCommit = isInterimRestartCommit
  }

  // why: C10 review (2026-07-02) — Parakeet EOU segments carry confidence 0 (FluidAudio's
  // streaming callback yields text only), so EVERY Parakeet segment badges VERIFY. That is
  // deliberate: the badge tells the truth ("unconfirmed by the engine") and the alternative —
  // faking a confidence or exempting an engine — violates the no-fake-AI rule. Revisit only
  // when FluidAudio surfaces a real per-segment confidence (PLAN-2026-06-22 open Q1).
  var requiresVerification: Bool {
    isStopCommittedPlaceholder || isInterimRestartCommit || confidence < 0.82
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    let startedAtSeconds = try container.decode(TimeInterval.self, forKey: .startedAt)
    startedAt = Date(timeIntervalSince1970: startedAtSeconds)
    text = try container.decode(String.self, forKey: .text)
    translatedText = try container.decodeIfPresent(String.self, forKey: .translatedText)
    confidence = try container.decode(Double.self, forKey: .confidence)
    sourceLanguageCode = try container.decode(String.self, forKey: .sourceLanguageCode)
    let sourceRawValue = try container.decode(String.self, forKey: .source)
    guard let decodedSource = Source(rawValue: sourceRawValue) else {
      throw DecodingError.dataCorruptedError(
        forKey: .source,
        in: container,
        debugDescription: "Unknown transcript source '\(sourceRawValue)'"
      )
    }
    source = decodedSource
    isStopCommittedPlaceholder =
      try container.decodeIfPresent(Bool.self, forKey: .isStopCommittedPlaceholder) ?? false
    isInterimRestartCommit =
      try container.decodeIfPresent(Bool.self, forKey: .isInterimRestartCommit) ?? false
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(startedAt.timeIntervalSince1970, forKey: .startedAt)
    try container.encode(text, forKey: .text)
    try container.encodeIfPresent(translatedText, forKey: .translatedText)
    try container.encode(confidence, forKey: .confidence)
    try container.encode(sourceLanguageCode, forKey: .sourceLanguageCode)
    try container.encode(source.rawValue, forKey: .source)
    try container.encode(isStopCommittedPlaceholder, forKey: .isStopCommittedPlaceholder)
    try container.encode(isInterimRestartCommit, forKey: .isInterimRestartCommit)
  }
}
