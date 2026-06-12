import Foundation
import Synchronization
import Testing

@testable import Dspeech

struct TransmissionAssemblerTests {
  private let t0 = Date(timeIntervalSince1970: 1_000)

  @Test func opensTransmissionOnNonEmptyPartial() {
    var assembler = Self.makeAssembler()

    let updates = assembler.process(.partial(text: "tower", at: t0))

    let opened = Self.requireOpened(updates)
    #expect(opened.startedAt == t0)
    #expect(opened.endedAt == t0)
    #expect(opened.text == "")
    #expect(opened.segments.isEmpty)
    #expect(opened.classification == .filtered(.nonRelevant))
    #expect(assembler.process(.partial(text: "   ", at: t0.addingTimeInterval(0.1))) == [])
  }

  @Test func opensTransmissionOnFragmentWithTextAndSegment() {
    var assembler = Self.makeAssembler()
    let segment = Self.segment("Tower november one two three")

    let updates = assembler.process(.fragment(segment: segment, speaker: nil, at: t0))

    let opened = Self.requireOpened(updates)
    #expect(opened.startedAt == t0)
    #expect(opened.endedAt == t0)
    #expect(opened.text == "Tower november one two three")
    #expect(opened.segments == [segment])
  }

  @Test func closesOpenTransmissionWhenTickObservesGapThreshold() {
    var assembler = Self.makeAssembler()
    let segment = Self.segment("Line up and wait")
    _ = assembler.process(.fragment(segment: segment, speaker: nil, at: t0))

    let updates = assembler.tick(now: t0.addingTimeInterval(3.5))

    let closed = Self.requireClosed(updates)
    #expect(closed.text == "Line up and wait")
    #expect(closed.endedAt == t0)
    #expect(assembler.tick(now: t0.addingTimeInterval(4)) == [])
  }

  @Test func closesOldTransmissionBeforeOpeningLateFragment() {
    var assembler = Self.makeAssembler()
    _ = assembler.process(
      .fragment(segment: Self.segment("Hold short runway two seven"), speaker: nil, at: t0))

    let updates = assembler.process(
      .fragment(
        segment: Self.segment("Cleared for takeoff"),
        speaker: nil,
        at: t0.addingTimeInterval(4)
      ))

    #expect(updates.count == 2)
    guard case .closed(let closed) = updates[0],
      case .opened(let opened) = updates[1]
    else {
      Issue.record("Expected close then open")
      return
    }
    #expect(closed.text == "Hold short runway two seven")
    #expect(closed.endedAt == t0)
    #expect(opened.startedAt == t0.addingTimeInterval(4))
    #expect(opened.text == "Cleared for takeoff")
    #expect(opened.id != closed.id)
  }

  @Test func taskRestartMarkerDoesNotCloseTransmission() {
    var assembler = Self.makeAssembler()
    _ = assembler.process(
      .fragment(segment: Self.segment("Maintain present heading"), speaker: nil, at: t0))

    #expect(assembler.process(.taskRestart(at: t0.addingTimeInterval(1))) == [])
    let updates = assembler.process(
      .fragment(
        segment: Self.segment("and climb flight level two zero zero"),
        speaker: nil,
        at: t0.addingTimeInterval(1.2)
      ))

    let updated = Self.requireUpdated(updates)
    #expect(updated.text == "Maintain present heading and climb flight level two zero zero")
  }

  @Test func finishClosesOpenTransmissionUnconditionally() {
    var assembler = Self.makeAssembler()
    _ = assembler.process(.partial(text: "tower", at: t0))

    let updates = assembler.finish(at: t0.addingTimeInterval(0.5))

    let closed = Self.requireClosed(updates)
    #expect(closed.startedAt == t0)
    #expect(closed.endedAt == t0.addingTimeInterval(0.5))
    #expect(assembler.finish(at: t0.addingTimeInterval(1)) == [])
  }

  @Test func joinsConsecutiveFragmentsWithSingleSpace() {
    var assembler = Self.makeAssembler()
    _ = assembler.process(.fragment(segment: Self.segment("Contact tower"), speaker: nil, at: t0))

    let updates = assembler.process(
      .fragment(
        segment: Self.segment("one one eight decimal seven"),
        speaker: nil,
        at: t0.addingTimeInterval(0.4)
      ))

    let updated = Self.requireUpdated(updates)
    #expect(updated.text == "Contact tower one one eight decimal seven")
  }

  @Test func collapsesTwoWordOverlap() {
    var assembler = Self.makeAssembler()
    _ = assembler.process(
      .fragment(segment: Self.segment("alpha bravo charlie delta"), speaker: nil, at: t0))

    let updates = assembler.process(
      .fragment(
        segment: Self.segment("charlie delta echo foxtrot"),
        speaker: nil,
        at: t0.addingTimeInterval(0.4)
      ))

    let updated = Self.requireUpdated(updates)
    #expect(updated.text == "alpha bravo charlie delta echo foxtrot")
  }

  @Test func collapsesLongestThreeWordOverlap() {
    var assembler = Self.makeAssembler()
    _ = assembler.process(
      .fragment(segment: Self.segment("alpha bravo charlie delta"), speaker: nil, at: t0))

    let updates = assembler.process(
      .fragment(
        segment: Self.segment("bravo charlie delta echo"),
        speaker: nil,
        at: t0.addingTimeInterval(0.4)
      ))

    let updated = Self.requireUpdated(updates)
    #expect(updated.text == "alpha bravo charlie delta echo")
  }

  @Test func fullContainmentOverlapEmitsNoUpdate() {
    var assembler = Self.makeAssembler()
    _ = assembler.process(
      .fragment(segment: Self.segment("one two three four"), speaker: nil, at: t0))

    let updates = assembler.process(
      .fragment(
        segment: Self.segment("two three four"), speaker: nil, at: t0.addingTimeInterval(0.4)))

    #expect(updates == [])
  }

  @Test func doesNotCollapseSingleWordOverlapBelowMinimum() {
    var assembler = Self.makeAssembler()
    _ = assembler.process(
      .fragment(segment: Self.segment("alpha bravo charlie"), speaker: nil, at: t0))

    let updates = assembler.process(
      .fragment(
        segment: Self.segment("charlie delta"), speaker: nil, at: t0.addingTimeInterval(0.4)))

    let updated = Self.requireUpdated(updates)
    #expect(updated.text == "alpha bravo charlie charlie delta")
  }

  @Test func collapsesOverlapIgnoringCaseAndPunctuation() {
    var assembler = Self.makeAssembler()
    _ = assembler.process(
      .fragment(segment: Self.segment("Climb, and maintain"), speaker: nil, at: t0))

    let updates = assembler.process(
      .fragment(
        segment: Self.segment("AND maintain five thousand"),
        speaker: nil,
        at: t0.addingTimeInterval(0.4)
      ))

    let updated = Self.requireUpdated(updates)
    #expect(updated.text == "Climb, and maintain five thousand")
  }

  @Test func classificationUpgradeMidTransmissionEmitsUpdateWithAllSpeakers() {
    let classifiedInputs = Mutex([(String, [SpeakerMatchDecision])]())
    var assembler = Self.makeAssembler { text, speakers, _ in
      classifiedInputs.withLock { $0.append((text, speakers)) }
      if text.localizedCaseInsensitiveContains("november one two three") {
        return TransmissionClassification.displayed(.callSignMatch)
      }
      return TransmissionClassification.filtered(.nonRelevant)
    }
    let pilot = SpeakerMatchDecision.pilot(slot: .primary, score: 0.91)
    let dispatcher = SpeakerMatchDecision.nonPilot(bestPilotScore: 0.12)
    _ = assembler.process(
      .fragment(segment: Self.segment("continue straight ahead"), speaker: pilot, at: t0))

    let updates = assembler.process(
      .fragment(
        segment: Self.segment("november one two three"),
        speaker: dispatcher,
        at: t0.addingTimeInterval(0.4)
      ))

    let updated = Self.requireUpdated(updates)
    #expect(updated.classification == TransmissionClassification.displayed(.callSignMatch))
    let lastClassifiedInput = classifiedInputs.withLock { $0.last }
    #expect(lastClassifiedInput?.0 == "continue straight ahead november one two three")
    #expect(lastClassifiedInput?.1 == [pilot, dispatcher])
  }

  @Test func classifyReceivesCurrentTransmissionEndedAt() {
    let classifiedEndedAt = Mutex([Date]())
    var assembler = Self.makeAssembler { _, _, endedAt in
      classifiedEndedAt.withLock { $0.append(endedAt) }
      return .filtered(.nonRelevant)
    }

    _ = assembler.process(.fragment(segment: Self.segment("contact tower"), speaker: nil, at: t0))
    _ = assembler.process(
      .fragment(
        segment: Self.segment("one one eight decimal seven"), speaker: nil,
        at: t0.addingTimeInterval(0.6)))

    let endedAtValues = classifiedEndedAt.withLock { $0 }
    #expect(endedAtValues.contains(t0))
    #expect(endedAtValues.contains(t0.addingTimeInterval(0.6)))
  }

  @Test func duplicateFragmentEmitsNoUpdate() {
    var assembler = Self.makeAssembler()
    _ = assembler.process(.fragment(segment: Self.segment("cleared to land"), speaker: nil, at: t0))

    let updates = assembler.process(
      .fragment(
        segment: Self.segment("cleared to land"), speaker: nil, at: t0.addingTimeInterval(0.4)))

    #expect(updates == [])
  }

  @Test func partialsKeepTransmissionOpenWithoutChangingText() {
    var assembler = Self.makeAssembler()
    _ = assembler.process(
      .fragment(segment: Self.segment("descend two thousand"), speaker: nil, at: t0))

    #expect(
      assembler.process(
        .partial(text: "descend two thousand report established", at: t0.addingTimeInterval(2)))
        == [])
    #expect(assembler.tick(now: t0.addingTimeInterval(4)) == [])

    let updates = assembler.process(
      .fragment(
        segment: Self.segment("report established"), speaker: nil, at: t0.addingTimeInterval(4.2)))
    let updated = Self.requireUpdated(updates)
    #expect(updated.text == "descend two thousand report established")
  }

  @Test func clampsOutOfRangeGapConfig() {
    #expect(
      TransmissionAssemblerConfig(transmissionGapSeconds: 0.25, overlapMergeMinWords: 2)
        .transmissionGapSeconds == 2)
    #expect(
      TransmissionAssemblerConfig(transmissionGapSeconds: 12, overlapMergeMinWords: 2)
        .transmissionGapSeconds == 6)
    #expect(TransmissionAssemblerConfig.default.transmissionGapSeconds == 3.5)
    #expect(TransmissionAssemblerConfig.default.overlapMergeMinWords == 2)
  }

  @Test func preservesTransmissionInvariantsAcrossGeneratedOverlapStreams() {
    let generatedCaseCount = 500
    var generator = OverlapStreamGenerator(seed: 0xD5EE_C220_12)
    for caseIndex in 0..<generatedCaseCount {
      let generated = generator.stream(caseIndex: caseIndex)
      var assembler = Self.makeAssembler()
      var lastTextById: [UUID: String] = [:]
      var opened: Set<UUID> = []
      var closedCounts: [UUID: Int] = [:]
      var closedIds: Set<UUID> = []

      for event in generated.events {
        let updates = assembler.process(event)
        Self.assertUpdateInvariants(
          updates,
          lastTextById: &lastTextById,
          opened: &opened,
          closedCounts: &closedCounts,
          closedIds: &closedIds
        )
      }

      let finishUpdates = assembler.finish(at: generated.finishAt)
      Self.assertUpdateInvariants(
        finishUpdates,
        lastTextById: &lastTextById,
        opened: &opened,
        closedCounts: &closedCounts,
        closedIds: &closedIds
      )

      #expect(opened.count == 1)
      #expect(closedCounts.values.reduce(0, +) == 1)
      let finalText = finishUpdates.last?.transmission.text
      #expect(finalText == generated.groundTruth)
      #expect(!Self.hasImmediateRepeatedTokenRun(finalText ?? "", runLength: 2))
    }
    print("PBT_CASE_COUNT transmissionAssembler=500")
    #expect(generatedCaseCount == 500)
  }

  fileprivate static func segment(_ text: String) -> TranscriptSegment {
    TranscriptSegment(
      startedAt: Date(timeIntervalSince1970: 0),
      text: text,
      confidence: 0.95,
      sourceLanguageCode: "en",
      source: .liveATC
    )
  }

  private static func makeAssembler(
    classify:
      @escaping @Sendable (String, [SpeakerMatchDecision], Date) -> TransmissionClassification = {
        _, _, _ in .filtered(.nonRelevant)
      }
  ) -> TransmissionAssembler {
    TransmissionAssembler(config: .default, localeIdentifier: "en-US", classify: classify)
  }

  private static func requireOpened(_ updates: [TransmissionUpdate]) -> Transmission {
    guard updates.count == 1, case .opened(let transmission) = updates[0] else {
      Issue.record("Expected one opened update")
      return emptyTransmission()
    }
    return transmission
  }

  private static func requireUpdated(_ updates: [TransmissionUpdate]) -> Transmission {
    guard updates.count == 1, case .updated(let transmission) = updates[0] else {
      Issue.record("Expected one updated update")
      return emptyTransmission()
    }
    return transmission
  }

  private static func requireClosed(_ updates: [TransmissionUpdate]) -> Transmission {
    guard updates.count == 1, case .closed(let transmission) = updates[0] else {
      Issue.record("Expected one closed update")
      return emptyTransmission()
    }
    return transmission
  }

  private static func emptyTransmission() -> Transmission {
    Transmission(
      startedAt: Date(timeIntervalSince1970: 0),
      endedAt: Date(timeIntervalSince1970: 0),
      text: "",
      segments: [],
      classification: .filtered(.nonRelevant),
      localeIdentifier: "en-US"
    )
  }

  private static func assertUpdateInvariants(
    _ updates: [TransmissionUpdate],
    lastTextById: inout [UUID: String],
    opened: inout Set<UUID>,
    closedCounts: inout [UUID: Int],
    closedIds: inout Set<UUID>
  ) {
    for update in updates {
      let transmission = update.transmission
      #expect(!closedIds.contains(transmission.id))
      let previousText = lastTextById[transmission.id] ?? ""
      #expect(transmission.text.count >= previousText.count)
      #expect(transmission.text.hasPrefix(previousText))
      switch update {
      case .opened:
        #expect(!opened.contains(transmission.id))
        opened.insert(transmission.id)
      case .updated:
        #expect(opened.contains(transmission.id))
      case .closed:
        #expect(opened.contains(transmission.id))
        closedCounts[transmission.id, default: 0] += 1
        closedIds.insert(transmission.id)
      }
      lastTextById[transmission.id] = transmission.text
    }
  }

  private static func hasImmediateRepeatedTokenRun(_ text: String, runLength: Int) -> Bool {
    let tokens = tokenize(text)
    guard runLength > 0, tokens.count >= runLength * 2 else { return false }
    for index in 0...(tokens.count - runLength * 2) {
      let first = tokens[index..<(index + runLength)]
      let second = tokens[(index + runLength)..<(index + runLength * 2)]
      if Array(first) == Array(second) { return true }
    }
    return false
  }

  private static func tokenize(_ text: String) -> [String] {
    text
      .lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
  }
}

private struct GeneratedOverlapStream {
  let groundTruth: String
  let events: [TransmissionAssemblerInput]
  let finishAt: Date
}

private struct OverlapStreamGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func stream(caseIndex: Int) -> GeneratedOverlapStream {
    let wordCount = 8 + Int(next() % 18)
    let words = (0..<wordCount).map { "case\(caseIndex)word\($0)" }
    var fragments: [String] = []
    var cursor = 0
    var previousStart = 0
    var previousEnd = 0
    while cursor < words.count {
      let chunkLength = 2 + Int(next() % 5)
      let end = min(words.count, cursor + chunkLength)
      let maxOverlap = min(3, previousEnd - previousStart, cursor)
      let overlap =
        fragments.isEmpty || maxOverlap < 2 ? 0 : 2 + Int(next() % UInt64(maxOverlap - 1))
      let start = cursor - overlap
      fragments.append(words[start..<end].joined(separator: " "))
      previousStart = start
      previousEnd = end
      cursor = end
    }
    let base = Date(timeIntervalSince1970: TimeInterval(10_000 + caseIndex * 100))
    var events: [TransmissionAssemblerInput] = []
    for (index, fragment) in fragments.enumerated() {
      let at = base.addingTimeInterval(TimeInterval(index) * 0.35)
      if next().isMultiple(of: 3) {
        events.append(.partial(text: fragment, at: at.addingTimeInterval(0.05)))
      }
      if next().isMultiple(of: 5) {
        events.append(.taskRestart(at: at.addingTimeInterval(0.08)))
      }
      events.append(
        .fragment(segment: TransmissionAssemblerTests.segment(fragment), speaker: nil, at: at))
    }
    return GeneratedOverlapStream(
      groundTruth: words.joined(separator: " "),
      events: events,
      finishAt: base.addingTimeInterval(TimeInterval(fragments.count) * 0.35 + 0.2)
    )
  }

  private mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}
