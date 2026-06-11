import Foundation

struct TransmissionAssemblerConfig: Equatable, Sendable {
  var transmissionGapSeconds: TimeInterval
  var overlapMergeMinWords: Int

  static let `default` = TransmissionAssemblerConfig(
    transmissionGapSeconds: 3.5,
    overlapMergeMinWords: 2
  )

  init(transmissionGapSeconds: TimeInterval = 3.5, overlapMergeMinWords: Int = 2) {
    self.transmissionGapSeconds = min(6, max(2, transmissionGapSeconds))
    self.overlapMergeMinWords = max(1, overlapMergeMinWords)
  }
}

enum TransmissionAssemblerInput: Sendable {
  case partial(text: String, at: Date)
  case fragment(segment: TranscriptSegment, speaker: SpeakerMatchDecision?, at: Date)
  case taskRestart(at: Date)
}

struct TransmissionAssembler {
  private struct OpenTransmission {
    let id: UUID
    let startedAt: Date
    var endedAt: Date
    var text: String
    var segments: [TranscriptSegment]
    var classification: TransmissionClassification
    var speakers: [SpeakerMatchDecision]
    var lastSpeechEvidenceAt: Date
    let localeIdentifier: String

    func transmission(endedAt overrideEndedAt: Date? = nil) -> Transmission {
      Transmission(
        id: id,
        startedAt: startedAt,
        endedAt: overrideEndedAt ?? endedAt,
        text: text,
        segments: segments,
        classification: classification,
        localeIdentifier: localeIdentifier
      )
    }
  }

  private struct TokenSpan {
    let value: String
    let end: String.Index
  }

  private let config: TransmissionAssemblerConfig
  private let localeIdentifier: String
  private let classify: @Sendable (String, [SpeakerMatchDecision]) -> TransmissionClassification
  private var openTransmission: OpenTransmission?

  init(
    config: TransmissionAssemblerConfig,
    localeIdentifier: String,
    classify:
      @escaping @Sendable (_ text: String, _ speakers: [SpeakerMatchDecision])
      -> TransmissionClassification
  ) {
    self.config = config
    self.localeIdentifier = localeIdentifier
    self.classify = classify
  }

  mutating func process(_ input: TransmissionAssemblerInput) -> [TransmissionUpdate] {
    switch input {
    case .partial(let text, let at):
      var updates = closeIfGapReached(now: at)
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return updates }
      if openTransmission == nil {
        openTransmission = makeOpenTransmission(startedAt: at, evidenceAt: at, speakers: [])
        if let transmission = openTransmission?.transmission() {
          updates.append(.opened(transmission))
        }
      } else {
        openTransmission?.lastSpeechEvidenceAt = at
        openTransmission?.endedAt = at
      }
      return updates
    case .fragment(let segment, let speaker, let at):
      var updates = closeIfGapReached(now: at)
      updates.append(contentsOf: processFragment(segment: segment, speaker: speaker, at: at))
      return updates
    case .taskRestart(let at):
      return closeIfGapReached(now: at)
    }
  }

  mutating func tick(now: Date) -> [TransmissionUpdate] {
    closeIfGapReached(now: now)
  }

  mutating func finish(at: Date) -> [TransmissionUpdate] {
    guard let current = openTransmission else { return [] }
    return [closeOpenTransmission(current, endedAt: at)]
  }

  private mutating func processFragment(
    segment: TranscriptSegment,
    speaker: SpeakerMatchDecision?,
    at: Date
  ) -> [TransmissionUpdate] {
    let fragmentText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !fragmentText.isEmpty else {
      if openTransmission != nil {
        openTransmission?.lastSpeechEvidenceAt = at
        openTransmission?.endedAt = at
        if let speaker {
          openTransmission?.speakers.append(speaker)
        }
      }
      return []
    }

    let didOpen = openTransmission == nil
    if openTransmission == nil {
      openTransmission = makeOpenTransmission(
        startedAt: at,
        evidenceAt: at,
        speakers: speaker.map { [$0] } ?? []
      )
    } else {
      openTransmission?.lastSpeechEvidenceAt = at
      openTransmission?.endedAt = at
      if let speaker {
        openTransmission?.speakers.append(speaker)
      }
    }

    guard var current = openTransmission else { return [] }
    let appendix = Self.appendix(
      existingText: current.text,
      fragmentText: fragmentText,
      minimumOverlapWords: config.overlapMergeMinWords
    )
    guard !appendix.isEmpty else {
      openTransmission = current
      return []
    }

    current.text = current.text.isEmpty ? appendix : "\(current.text) \(appendix)"
    current.segments.append(segment)
    current.classification = classify(current.text, current.speakers)
    current.endedAt = at
    current.lastSpeechEvidenceAt = at
    openTransmission = current

    let transmission = current.transmission()
    return [didOpen ? .opened(transmission) : .updated(transmission)]
  }

  private func makeOpenTransmission(
    startedAt: Date,
    evidenceAt: Date,
    speakers: [SpeakerMatchDecision]
  ) -> OpenTransmission {
    OpenTransmission(
      id: UUID(),
      startedAt: startedAt,
      endedAt: evidenceAt,
      text: "",
      segments: [],
      classification: classify("", speakers),
      speakers: speakers,
      lastSpeechEvidenceAt: evidenceAt,
      localeIdentifier: localeIdentifier
    )
  }

  private mutating func closeIfGapReached(now: Date) -> [TransmissionUpdate] {
    guard let current = openTransmission else { return [] }
    guard now.timeIntervalSince(current.lastSpeechEvidenceAt) >= config.transmissionGapSeconds
    else {
      return []
    }
    return [closeOpenTransmission(current, endedAt: current.lastSpeechEvidenceAt)]
  }

  private mutating func closeOpenTransmission(
    _ current: OpenTransmission,
    endedAt: Date
  ) -> TransmissionUpdate {
    openTransmission = nil
    return .closed(current.transmission(endedAt: endedAt))
  }

  private static func appendix(
    existingText: String,
    fragmentText: String,
    minimumOverlapWords: Int
  ) -> String {
    guard !existingText.isEmpty else { return fragmentText }
    let existingTokens = tokenSpans(in: existingText)
    let fragmentTokens = tokenSpans(in: fragmentText)
    let maximumOverlap = min(existingTokens.count, fragmentTokens.count)
    guard maximumOverlap >= minimumOverlapWords else { return fragmentText }
    for overlap in stride(from: maximumOverlap, through: minimumOverlapWords, by: -1) {
      let existingSuffix = existingTokens.suffix(overlap).map(\.value)
      let fragmentPrefix = fragmentTokens.prefix(overlap).map(\.value)
      guard existingSuffix == fragmentPrefix else { continue }
      if overlap == fragmentTokens.count { return "" }
      let dropEnd = fragmentTokens[overlap - 1].end
      return String(fragmentText[dropEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return fragmentText
  }

  private static func tokenSpans(in text: String) -> [TokenSpan] {
    var spans: [TokenSpan] = []
    var tokenStart: String.Index?
    var cursor = text.startIndex
    while cursor < text.endIndex {
      if text[cursor].isAlphanumeric {
        if tokenStart == nil {
          tokenStart = cursor
        }
      } else if let start = tokenStart {
        spans.append(TokenSpan(value: String(text[start..<cursor]).lowercased(), end: cursor))
        tokenStart = nil
      }
      cursor = text.index(after: cursor)
    }
    if let start = tokenStart {
      spans.append(
        TokenSpan(value: String(text[start..<text.endIndex]).lowercased(), end: text.endIndex))
    }
    return spans
  }
}

extension Character {
  fileprivate var isAlphanumeric: Bool {
    unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
  }
}
