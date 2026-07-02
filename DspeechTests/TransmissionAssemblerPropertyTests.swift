import Foundation
import Testing

@testable import Dspeech

// Property-based tests for the transmission assembler — the card builder that splits the ASR stream
// on the silence gap. Over randomized input scripts these pin the invariants tied to real device
// bugs: a card can never end before it began (the crossed-timestamp audit), re-emitted unchanged
// partials never outlast the gap (the "whole flight as one card" bug), gaps split into separate
// cards, and overlapping fragments don't duplicate (the replay-tail dedup). Deterministic seeded
// PRNG — see PropertyTestSupport.
struct TransmissionAssemblerPropertyTests {

  // A transmission can never end before it began: every emitted card has endedAt >= startedAt, even
  // under out-of-order (backwards-jumping) input timestamps. (The crossed-timestamp audit.)
  @Test func everyEmittedTransmissionHasEndedAtAtLeastStartedAt() {
    var rng = SeededGenerator(seed: 0x7A55_0001)
    var exercised = 0
    for _ in 0..<300 {
      var assembler = makeAssembler()
      var time = assemblerT0
      var emitted: [Transmission] = []
      for _ in 0..<Int.random(in: 1...20, using: &rng) {
        time = time.addingTimeInterval(Double(Int.random(in: -10...50, using: &rng)) / 10)
        switch Int.random(in: 0...3, using: &rng) {
        case 0:
          emitted += assembler.process(.partial(text: randomWords(using: &rng), at: time))
            .map(\.transmission)
        case 1:
          emitted += assembler.process(
            .fragment(segment: seg(randomWords(using: &rng)), speaker: nil, at: time)
          ).map(\.transmission)
        case 2:
          emitted += assembler.process(.taskRestart(at: time)).map(\.transmission)
        default:
          emitted += assembler.tick(now: time).map(\.transmission)
        }
      }
      emitted += assembler.finish(at: time.addingTimeInterval(10)).map(\.transmission)
      for transmission in emitted {
        #expect(
          transmission.endedAt >= transmission.startedAt,
          "crossed timestamp: started=\(transmission.startedAt) ended=\(transmission.endedAt)")
      }
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // Two speech inputs separated by at least the gap become TWO transmissions: the first closes and
  // the second opens with a distinct id.
  @Test func inputsSeparatedByTheGapBecomeSeparateTransmissions() {
    var rng = SeededGenerator(seed: 0x7A55_0002)
    let gap = TransmissionAssemblerConfig.default.transmissionGapSeconds
    var exercised = 0
    for _ in 0..<300 {
      var assembler = makeAssembler()
      let first = assembler.process(
        .fragment(segment: seg(randomWords(using: &rng)), speaker: nil, at: assemblerT0))
      let openedFirst = opened(in: first)
      let second = assembler.process(
        .fragment(
          segment: seg(randomWords(using: &rng)), speaker: nil,
          at: assemblerT0.addingTimeInterval(gap + 0.5)))
      #expect(closedCount(in: second) == 1, "first transmission did not close across the gap")
      if let openedFirst, let openedSecond = opened(in: second) {
        #expect(openedFirst.id != openedSecond.id, "second transmission reused the first id")
      }
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // Re-emitted UNCHANGED partials are silence, not speech: they never refresh the gap timer, so the
  // card still closes once the gap elapses from the FIRST partial. (The dictaphone bug.)
  @Test func unchangedPartialsDoNotOutlastTheGap() {
    var rng = SeededGenerator(seed: 0x7A55_0003)
    let gap = TransmissionAssemblerConfig.default.transmissionGapSeconds
    var exercised = 0
    for _ in 0..<300 {
      var assembler = makeAssembler()
      let text = randomWords(using: &rng)
      _ = assembler.process(.partial(text: text, at: assemblerT0))
      // re-emit the same partial repeatedly, all within the gap of the first
      for i in 1...Int.random(in: 1...5, using: &rng) {
        let at = assemblerT0.addingTimeInterval(Double(i) * 0.3)
        _ = assembler.process(.partial(text: text, at: at))
      }
      let closing = assembler.tick(now: assemblerT0.addingTimeInterval(gap + 0.5))
      #expect(closedCount(in: closing) == 1, "unchanged partials kept the card alive past the gap")
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // Re-feeding an identical multi-word fragment within the gap adds nothing — the overlap-merge
  // dedup drops the fully-overlapping text instead of duplicating it. (The replay-tail dedup.)
  @Test func reFeedingIdenticalFragmentDoesNotDuplicate() {
    var rng = SeededGenerator(seed: 0x7A55_0004)
    var exercised = 0
    for _ in 0..<300 {
      var assembler = makeAssembler()
      let text = randomWords(minWords: 2, using: &rng)
      _ = assembler.process(.fragment(segment: seg(text), speaker: nil, at: assemblerT0))
      _ = assembler.process(
        .fragment(segment: seg(text), speaker: nil, at: assemblerT0.addingTimeInterval(0.2)))
      let closed = assembler.finish(at: assemblerT0.addingTimeInterval(5))
      #expect(
        lastText(in: closed) == text,
        "re-feeding an identical fragment duplicated text: \(lastText(in: closed) ?? "nil")")
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // Assembly is deterministic modulo the random transmission ids: two assemblers run on the same
  // input script emit the same kinds, text, and timestamps step for step.
  @Test func assemblyIsDeterministicModuloIDs() {
    var rng = SeededGenerator(seed: 0x7A55_0005)
    var exercised = 0
    for _ in 0..<200 {
      let script = randomScript(using: &rng)
      let first = runScript(script)
      let second = runScript(script)
      #expect(first == second)
      exercised += 1
    }
    #expect(exercised >= 180, "too few cases reached the assertion: \(exercised)")
  }

  // finish() closes any open transmission and is idempotent: a second finish emits nothing.
  @Test func finishClosesOpenTransmissionAndIsIdempotent() {
    var rng = SeededGenerator(seed: 0x7A55_0006)
    var exercised = 0
    for _ in 0..<300 {
      var assembler = makeAssembler()
      let didOpen = Bool.random(using: &rng)
      if didOpen {
        _ = assembler.process(
          .fragment(segment: seg(randomWords(using: &rng)), speaker: nil, at: assemblerT0))
      }
      let firstFinish = assembler.finish(at: assemblerT0.addingTimeInterval(5))
      let secondFinish = assembler.finish(at: assemblerT0.addingTimeInterval(10))
      #expect(closedCount(in: firstFinish) == (didOpen ? 1 : 0))
      #expect(secondFinish.isEmpty, "second finish emitted updates")
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // A fragment sharing a 2+word seam with the existing text appends only the NEW tail — the actual
  // replay-tail dedup across task restarts, not just the fully-identical case.
  @Test func partialOverlapAppendsOnlyTheNewTail() {
    var rng = SeededGenerator(seed: 0x7A55_0007)
    let overlap = 2
    var exercised = 0
    for _ in 0..<300 {
      let total = Int.random(in: 4...7, using: &rng)
      let words = randomDistinctWords(count: total, using: &rng)
      let existingCount = Int.random(in: overlap...(total - 1), using: &rng)
      let existing = words[0..<existingCount].joined(separator: " ")
      let fragment = words[(existingCount - overlap)...].joined(separator: " ")
      var assembler = makeAssembler()
      _ = assembler.process(.fragment(segment: seg(existing), speaker: nil, at: assemblerT0))
      _ = assembler.process(
        .fragment(segment: seg(fragment), speaker: nil, at: assemblerT0.addingTimeInterval(0.2)))
      let closed = assembler.finish(at: assemblerT0.addingTimeInterval(5))
      #expect(
        lastText(in: closed) == words.joined(separator: " "),
        "partial overlap did not append tail-only: \(lastText(in: closed) ?? "nil")")
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // A task restart closes the open transmission once the gap has elapsed, but not within it.
  @Test func taskRestartClosesAfterGapNotWithin() {
    var rng = SeededGenerator(seed: 0x7A55_0008)
    let gap = TransmissionAssemblerConfig.default.transmissionGapSeconds
    var exercised = 0
    for _ in 0..<300 {
      var assembler = makeAssembler()
      _ = assembler.process(
        .fragment(segment: seg(randomWords(using: &rng)), speaker: nil, at: assemblerT0))
      let within = assembler.process(.taskRestart(at: assemblerT0.addingTimeInterval(gap - 0.5)))
      #expect(closedCount(in: within) == 0, "task restart within the gap closed the transmission")
      let after = assembler.process(.taskRestart(at: assemblerT0.addingTimeInterval(gap + 0.5)))
      #expect(closedCount(in: after) == 1, "task restart after the gap did not close")
      exercised += 1
    }
    #expect(exercised >= 270, "too few cases reached the assertion: \(exercised)")
  }

  // The classification is refreshed as the accumulated text grows: a card flips from filtered to
  // displayed once an appended fragment makes it relevant.
  @Test func classificationRefreshesAsAccumulatedTextGrows() {
    var rng = SeededGenerator(seed: 0x7A55_0009)
    var exercised = 0
    for _ in 0..<200 {
      var assembler = TransmissionAssembler(
        config: .default, localeIdentifier: "en-US",
        classify: { text, _, _ in
          text.contains("tower") ? .displayed(.callSignMatch) : .filtered(.nonRelevant)
        })
      let firstWord = ["cleared", "contact", "ground", "runway"].randomElement(using: &rng)!
      let first = assembler.process(
        .fragment(segment: seg(firstWord), speaker: nil, at: assemblerT0))
      #expect(lastClassification(in: first) == .filtered(.nonRelevant))
      let second = assembler.process(
        .fragment(segment: seg("tower"), speaker: nil, at: assemblerT0.addingTimeInterval(0.2)))
      #expect(lastClassification(in: second) == .displayed(.callSignMatch))
      exercised += 1
    }
    #expect(exercised >= 180, "too few cases reached the assertion: \(exercised)")
  }
}

// MARK: - Assembler-specific generators

private let assemblerT0 = Date(timeIntervalSince1970: 1_000)

private func makeAssembler() -> TransmissionAssembler {
  TransmissionAssembler(
    config: .default, localeIdentifier: "en-US",
    classify: { _, _, _ in .filtered(.nonRelevant) })
}

private func seg(_ text: String) -> TranscriptSegment {
  TranscriptSegment(
    startedAt: Date(timeIntervalSince1970: 0), text: text, confidence: 0.95,
    sourceLanguageCode: "en", source: .liveATC)
}

private let assemblerWords = [
  "tower", "cleared", "takeoff", "november", "one", "two", "three", "alpha", "bravo", "contact",
  "ground", "runway", "seven", "hold", "short", "line", "wait", "climb",
]

private func randomWords(minWords: Int = 1, using rng: inout SeededGenerator) -> String {
  let count = Int.random(in: max(1, minWords)...max(1, minWords) + 4, using: &rng)
  return (0..<count).map { _ in assemblerWords.randomElement(using: &rng)! }.joined(separator: " ")
}

private func opened(in updates: [TransmissionUpdate]) -> Transmission? {
  for update in updates { if case .opened(let transmission) = update { return transmission } }
  return nil
}

private func closedCount(in updates: [TransmissionUpdate]) -> Int {
  updates.filter { if case .closed = $0 { return true } else { return false } }.count
}

private func lastText(in updates: [TransmissionUpdate]) -> String? {
  updates.last.map(\.transmission.text)
}

private func lastClassification(in updates: [TransmissionUpdate]) -> TransmissionClassification? {
  updates.last.map(\.transmission.classification)
}

private func randomDistinctWords(count: Int, using rng: inout SeededGenerator) -> [String] {
  Array(assemblerWords.shuffled(using: &rng).prefix(count))
}

private struct UpdateProjection: Equatable {
  let kind: String
  let text: String
  let startedAt: Date
  let endedAt: Date
  let classification: TransmissionClassification
}

private enum ScriptStep {
  case partial(String, Date)
  case fragment(String, Date)
  case restart(Date)
  case tick(Date)
}

private func randomScript(using rng: inout SeededGenerator) -> [ScriptStep] {
  var time = assemblerT0
  return (0..<Int.random(in: 1...20, using: &rng)).map { _ in
    time = time.addingTimeInterval(Double(Int.random(in: 0...40, using: &rng)) / 10)
    switch Int.random(in: 0...3, using: &rng) {
    case 0: return .partial(randomWords(using: &rng), time)
    case 1: return .fragment(randomWords(using: &rng), time)
    case 2: return .restart(time)
    default: return .tick(time)
    }
  }
}

private func runScript(_ script: [ScriptStep]) -> [UpdateProjection] {
  var assembler = makeAssembler()
  var projections: [UpdateProjection] = []
  var lastTime = assemblerT0
  for step in script {
    let updates: [TransmissionUpdate]
    switch step {
    case .partial(let text, let at):
      updates = assembler.process(.partial(text: text, at: at))
      lastTime = at
    case .fragment(let text, let at):
      updates = assembler.process(.fragment(segment: seg(text), speaker: nil, at: at))
      lastTime = at
    case .restart(let at):
      updates = assembler.process(.taskRestart(at: at))
      lastTime = at
    case .tick(let at):
      updates = assembler.tick(now: at)
      lastTime = at
    }
    projections += project(updates)
  }
  projections += project(assembler.finish(at: lastTime.addingTimeInterval(10)))
  return projections
}

private func project(_ updates: [TransmissionUpdate]) -> [UpdateProjection] {
  updates.map { update in
    let kind: String
    switch update {
    case .opened: kind = "opened"
    case .updated: kind = "updated"
    case .closed: kind = "closed"
    }
    let transmission = update.transmission
    return UpdateProjection(
      kind: kind, text: transmission.text, startedAt: transmission.startedAt,
      endedAt: transmission.endedAt, classification: transmission.classification)
  }
}
