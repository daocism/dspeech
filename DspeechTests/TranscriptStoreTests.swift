import Foundation
import Testing

@testable import Dspeech

// why: data-at-rest protection is a device-enforced feature the Simulator does not honour, so we
// cannot read the attribute back; instead we spy the exact setAttributes calls the store makes and
// assert it REQUESTS completeUntilFirstUserAuthentication for every file/dir it creates.
private final class ProtectionSpyFileManager: FileManager, @unchecked Sendable {
  private(set) var protectionCalls: [(path: String, protection: FileProtectionType?)] = []
  override func setAttributes(
    _ attributes: [FileAttributeKey: Any], ofItemAtPath path: String
  ) throws {
    protectionCalls.append((path, attributes[.protectionKey] as? FileProtectionType))
    try super.setAttributes(attributes, ofItemAtPath: path)
  }
}

@MainActor
struct TranscriptStoreTests {
  @Test func sessionFilesUseCompleteUntilFirstUserAuthenticationProtection() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let spy = ProtectionSpyFileManager()
    let store = try FileTranscriptStore(rootDirectory: root, fileManager: spy) {
      Date(timeIntervalSince1970: 100)
    }

    let summary = try store.beginSession(localeIdentifier: "en-US")
    for segment in Self.segments() {
      try store.append(segment, to: summary.id)
    }
    try store.endSession(summary.id)

    #expect(
      !spy.protectionCalls.isEmpty,
      "store must apply data-at-rest protection to the files it creates")
    let unprotected = spy.protectionCalls.filter {
      $0.protection != .completeUntilFirstUserAuthentication
    }
    #expect(
      unprotected.isEmpty,
      "transcript files must use completeUntilFirstUserAuthentication; unprotected: \(unprotected.map(\.path))"
    )
  }

  @Test func roundTripPersistsSummaryAndSegments() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let start = Date(timeIntervalSince1970: 100)
    let end = Date(timeIntervalSince1970: 200)
    var dates = [start, end]
    let store = try FileTranscriptStore(rootDirectory: root) { dates.removeFirst() }

    let summary = try store.beginSession(localeIdentifier: "en-US")
    let segments = Self.segments()
    for segment in segments {
      try store.append(segment, to: summary.id)
    }
    try store.endSession(summary.id)

    let sessions = try store.sessions()
    #expect(sessions.count == 1)
    #expect(sessions.first?.id == summary.id)
    #expect(sessions.first?.startedAt == start)
    #expect(sessions.first?.endedAt == end)
    #expect(sessions.first?.segmentCount == 3)
    #expect(sessions.first?.localeIdentifier == "en-US")
    #expect(try store.segments(in: summary.id) == segments)
  }

  @Test func sessionSummaryCountsTransmissionsNotSegments() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let start = Date(timeIntervalSince1970: 100)
    let end = Date(timeIntervalSince1970: 200)
    var dates = [start, end]
    let store = try FileTranscriptStore(rootDirectory: root) { dates.removeFirst() }

    let summary = try store.beginSession(localeIdentifier: "en-US")
    let first = Self.transmission(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
      startedAt: Date(timeIntervalSince1970: 5),
      endedAt: Date(timeIntervalSince1970: 9),
      text: "Cleared to land runway two seven")
    let second = Self.transmission(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
      startedAt: Date(timeIntervalSince1970: 12),
      endedAt: Date(timeIntervalSince1970: 15),
      text: "Contact ground point niner")
    try store.append(first, to: summary.id)
    try store.append(second, to: summary.id)
    try store.endSession(summary.id)

    // why: segmentCount holds the TRANSMISSION count when transmissions exist — the relabeled
    // "transmissions" semantics. The legacy round-trip test only exercises the segment fallback.
    #expect(try store.sessions().first?.segmentCount == 2)
  }

  @Test func openSessionSurvivesStoreRecreation() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let store = try FileTranscriptStore(rootDirectory: root) { Date(timeIntervalSince1970: 300) }

    let summary = try store.beginSession(localeIdentifier: "fr-FR")
    let segments = Array(Self.segments().prefix(2))
    for segment in segments {
      try store.append(segment, to: summary.id)
    }

    let recovered = try FileTranscriptStore(rootDirectory: root)
    let sessions = try recovered.sessions()

    #expect(sessions.map(\.id) == [summary.id])
    #expect(sessions.first?.endedAt == nil)
    #expect(sessions.first?.localeIdentifier == "fr-FR")
    #expect(try recovered.segments(in: summary.id) == segments)
  }

  @Test func tornTailLineReturnsValidPrefix() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let store = try FileTranscriptStore(rootDirectory: root)
    let summary = try store.beginSession(localeIdentifier: "en-US")
    let segments = Array(Self.segments().prefix(2))
    for segment in segments {
      try store.append(segment, to: summary.id)
    }

    let segmentsURL =
      root
      .appendingPathComponent(summary.id.uuidString, isDirectory: true)
      .appendingPathComponent("segments.jsonl", isDirectory: false)
    let handle = try FileHandle(forWritingTo: segmentsURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"id\":\"not-finished\"".utf8))
    try handle.close()

    #expect(try store.segments(in: summary.id) == segments)
  }

  @Test func handWrittenJSONLineDecodesStableContract() throws {
    let fixture = """
      {"confidence":0.86,"id":"00000000-0000-0000-0000-000000000111","source":"replay","sourceLanguageCode":"en","startedAt":42,"text":"Tower, line up and wait","translatedText":"Tower, line up and wait translated"}
      """
    let segment = try JSONDecoder().decode(TranscriptSegment.self, from: Data(fixture.utf8))

    #expect(segment.id == UUID(uuidString: "00000000-0000-0000-0000-000000000111")!)
    #expect(segment.startedAt == Date(timeIntervalSince1970: 42))
    #expect(segment.text == "Tower, line up and wait")
    #expect(segment.translatedText == "Tower, line up and wait translated")
    #expect(segment.confidence == 0.86)
    #expect(segment.sourceLanguageCode == "en")
    #expect(segment.source == .replay)
  }

  @Test func exportTextUsesPinnedHeaderAndClockFormat() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let store = try FileTranscriptStore(rootDirectory: root) { Date(timeIntervalSince1970: 0) }
    let summary = try store.beginSession(localeIdentifier: "en-US")
    let first = Self.segment(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
      startedAt: Date(timeIntervalSince1970: 5),
      text: "Cleared to land")
    let second = Self.segment(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
      startedAt: Date(timeIntervalSince1970: 12),
      text: "Contact tower")

    try store.append(first, to: summary.id)
    try store.append(second, to: summary.id)

    #expect(
      try store.exportText(for: summary.id)
        == """
        Dspeech transcript  1970-01-01  en-US
        00:00:05  Cleared to land
        00:00:12  Contact tower
        """)
  }

  @Test func appendingClosedTransmissionWritesTransmissionHistory() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let store = try FileTranscriptStore(rootDirectory: root) { Date(timeIntervalSince1970: 0) }
    let summary = try store.beginSession(localeIdentifier: "en-US")
    let legacySegment = Self.segment(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000208")!,
      startedAt: Date(timeIntervalSince1970: 7),
      text: "Legacy fragment")
    let transmission = Self.transmission(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000209")!,
      startedAt: Date(timeIntervalSince1970: 5),
      endedAt: Date(timeIntervalSince1970: 9),
      text: "Cleared to land runway two seven")

    try store.append(legacySegment, to: summary.id)
    try store.append(transmission, to: summary.id)

    #expect(try store.transmissions(in: summary.id) == [transmission])
    #expect(try store.segments(in: summary.id).map(\.text) == [transmission.text])
    #expect(
      try store.exportText(for: summary.id)
        == """
        Dspeech transcript  1970-01-01  en-US
        00:00:05  Cleared to land runway two seven
        """)
  }

  @Test func openTransmissionIsRecoveredOnceAndRemovedAfterClose() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let store = try FileTranscriptStore(rootDirectory: root)
    let summary = try store.beginSession(localeIdentifier: "fr-FR")
    let open = Self.transmission(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000210")!,
      startedAt: Date(timeIntervalSince1970: 3),
      endedAt: Date(timeIntervalSince1970: 4),
      text: "Fox Papa unité deux trois contactez tour")

    try store.updateOpen(open, in: summary.id)
    #expect(try store.transmissions(in: summary.id) == [open])

    let closed = Self.transmission(
      id: open.id,
      startedAt: open.startedAt,
      endedAt: Date(timeIntervalSince1970: 5),
      text: "Fox Papa unité deux trois contactez tour")
    try store.append(closed, to: summary.id)

    #expect(try store.transmissions(in: summary.id) == [closed])
  }

  @Test func tornOpenTransmissionScratchIsSkippedAndClosedTransmissionsSurvive() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let store = try FileTranscriptStore(rootDirectory: root)
    let summary = try store.beginSession(localeIdentifier: "en-US")
    let closed = Self.transmission(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000260")!,
      startedAt: Date(timeIntervalSince1970: 3),
      endedAt: Date(timeIntervalSince1970: 4),
      text: "Cleared for takeoff runway two seven")
    try store.append(closed, to: summary.id)

    // why: simulate a crash mid-updateOpen leaving a torn (invalid-JSON) scratch — the non-atomic
    // write B uses can produce this. Recovery must SKIP it and still return the durable CLOSED log,
    // never throw on the whole session read.
    let scratchURL =
      root
      .appendingPathComponent(summary.id.uuidString, isDirectory: true)
      .appendingPathComponent("open-transmission.json", isDirectory: false)
    try Data(#"{"id":"00000000-0000-0000-0000-0000000"#.utf8).write(to: scratchURL)

    #expect(try store.transmissions(in: summary.id) == [closed])
    #expect(try store.segments(in: summary.id).map(\.text) == [closed.text])
  }

  @Test func legacySegmentOnlyExportStillWorksWithoutTransmissionFiles() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let store = try FileTranscriptStore(rootDirectory: root) { Date(timeIntervalSince1970: 0) }
    let summary = try store.beginSession(localeIdentifier: "en-US")
    let segment = Self.segment(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000211")!,
      startedAt: Date(timeIntervalSince1970: 21),
      text: "Contact tower")

    try store.append(segment, to: summary.id)

    #expect(try store.transmissions(in: summary.id).isEmpty)
    #expect(
      try store.exportText(for: summary.id)
        == """
        Dspeech transcript  1970-01-01  en-US
        00:00:21  Contact tower
        """)
  }

  @Test func stopPlaceholderOnlySessionSurvivesHistoryRead() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let store = try FileTranscriptStore(rootDirectory: root)
    let summary = try store.beginSession(localeIdentifier: "en-US")
    let placeholder = Self.segment(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!,
      startedAt: Date(timeIntervalSince1970: 15),
      text: "Hold short runway two seven",
      confidence: 0,
      isStopCommittedPlaceholder: true)

    try store.append(placeholder, to: summary.id)

    #expect(try store.segments(in: summary.id) == [placeholder])
  }

  @Test func immediatelyFollowingMatchingFinalDedupesStopPlaceholderOnRead() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let store = try FileTranscriptStore(rootDirectory: root) { Date(timeIntervalSince1970: 0) }
    let summary = try store.beginSession(localeIdentifier: "en-US")
    let placeholder = Self.segment(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000204")!,
      startedAt: Date(timeIntervalSince1970: 15),
      text: "Hold short runway two seven",
      confidence: 0,
      isStopCommittedPlaceholder: true)
    let final = Self.segment(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000205")!,
      startedAt: Date(timeIntervalSince1970: 16),
      text: "hold short runway two seven",
      confidence: 0.91)

    try store.append(placeholder, to: summary.id)
    try store.append(final, to: summary.id)

    #expect(try store.segments(in: summary.id) == [final])
  }

  @Test func exportTextDedupesStopPlaceholderWhenMatchingFinalFollows() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let store = try FileTranscriptStore(rootDirectory: root) { Date(timeIntervalSince1970: 0) }
    let summary = try store.beginSession(localeIdentifier: "en-US")
    let placeholder = Self.segment(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000206")!,
      startedAt: Date(timeIntervalSince1970: 15),
      text: "Hold short runway two seven",
      confidence: 0,
      isStopCommittedPlaceholder: true)
    let final = Self.segment(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000207")!,
      startedAt: Date(timeIntervalSince1970: 16),
      text: "hold short runway two seven",
      confidence: 0.91)

    try store.append(placeholder, to: summary.id)
    try store.append(final, to: summary.id)

    #expect(
      try store.exportText(for: summary.id)
        == """
        Dspeech transcript  1970-01-01  en-US
        00:00:16  hold short runway two seven
        """)
  }

  @Test func deleteSessionRemovesDirectoryAndListing() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let store = try FileTranscriptStore(rootDirectory: root)
    let summary = try store.beginSession(localeIdentifier: "en-US")
    let sessionURL = root.appendingPathComponent(summary.id.uuidString, isDirectory: true)

    try store.deleteSession(summary.id)

    #expect(!FileManager.default.fileExists(atPath: sessionURL.path))
    #expect(try store.sessions().isEmpty)
  }

  @Test func manyAppendsReadBackWithoutReopeningPerAppend() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let store = try FileTranscriptStore(rootDirectory: root)
    let summary = try store.beginSession(localeIdentifier: "en-US")
    let segments = (0..<10_000).map { index in
      Self.segment(
        id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
        startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
        text: "Transmission \(index)")
    }

    for segment in segments {
      try store.append(segment, to: summary.id)
    }

    let loaded = try store.segments(in: summary.id)
    #expect(loaded.count == 10_000)
    #expect(loaded.first == segments.first)
    #expect(loaded.last == segments.last)
  }

  @Test func sessionsSkipCorruptSummaryAndExposeCorruptSessionIDs() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let store = try FileTranscriptStore(rootDirectory: root)
    let valid = try store.beginSession(localeIdentifier: "en-US")
    let corruptID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
    let corruptDirectory = root.appendingPathComponent(corruptID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(
      to: corruptDirectory.appendingPathComponent("summary.json", isDirectory: false))

    let sessions = try store.sessions()

    #expect(sessions.map(\.id) == [valid.id])
    #expect(store.corruptSessionIDs() == [corruptID])
  }

  // MARK: - C6 structured JSONL export

  @Test func exportJSONLEmitsOneObjectPerTransmissionWithClassificationAndEngine() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let store = try FileTranscriptStore(rootDirectory: root) { Date(timeIntervalSince1970: 0) }
    let summary = try store.beginSession(localeIdentifier: "en-US")
    let first = Self.transmission(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000006A1")!,
      startedAt: Date(timeIntervalSince1970: 5),
      endedAt: Date(timeIntervalSince1970: 9),
      text: "November One Two Three Alpha Bravo, cleared to land")
    let second = Self.transmission(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000006A2")!,
      startedAt: Date(timeIntervalSince1970: 12),
      endedAt: Date(timeIntervalSince1970: 15),
      text: "Contact ground point niner")
    try store.append(first, to: summary.id)
    try store.append(second, to: summary.id)
    try store.setEngine("WhisperKit", for: summary.id)

    let lines = try store.exportJSONL(for: summary.id).split(
      separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == 2)

    let row = try Self.jsonObject(String(lines[0]))
    #expect(
      Set(row.keys) == [
        "confidence", "end", "engine", "id", "kind", "reason", "sourceLanguage", "start", "text",
        "v",
      ])
    #expect(row["id"] as? String == "00000000-0000-0000-0000-0000000006A1")
    #expect(row["start"] as? Double == 5)
    #expect(row["end"] as? Double == 9)
    #expect(row["kind"] as? String == "displayed")
    #expect(row["reason"] as? String == "callSignMatch")
    #expect(row["engine"] as? String == "WhisperKit")
    #expect(row["sourceLanguage"] as? String == "en")
    #expect(row["confidence"] as? Double == 0.91)
    #expect(row["text"] as? String == "November One Two Three Alpha Bravo, cleared to land")
    // M2 — every row carries the schema version as its own `v` field.
    #expect(row["v"] as? Int == 1)
  }

  @Test func exportJSONLForLegacySegmentsOmitsClassificationAndEnd() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let store = try FileTranscriptStore(rootDirectory: root) { Date(timeIntervalSince1970: 0) }
    let summary = try store.beginSession(localeIdentifier: "en-US")
    let segment = Self.segment(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000006B1")!,
      startedAt: Date(timeIntervalSince1970: 7),
      text: "Cleared for takeoff")
    try store.append(segment, to: summary.id)

    let lines = try store.exportJSONL(for: summary.id).split(separator: "\n")
    #expect(lines.count == 1)
    let row = try Self.jsonObject(String(lines[0]))
    // why: a legacy segment has no transmission-level classification or end time, so those keys are
    // omitted rather than emitted as null — a JSONL consumer can tell the two row shapes apart.
    #expect(row["kind"] == nil)
    #expect(row["reason"] == nil)
    #expect(row["end"] == nil)
    #expect(row["engine"] == nil)
    #expect(row["start"] as? Double == 7)
    #expect(row["text"] as? String == "Cleared for takeoff")
    // M2 — a legacy-segment row still carries the schema version.
    #expect(row["v"] as? Int == 1)
  }

  @Test func exportJSONLToleratesTornTail() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let store = try FileTranscriptStore(rootDirectory: root) { Date(timeIntervalSince1970: 0) }
    let summary = try store.beginSession(localeIdentifier: "en-US")
    try store.append(
      Self.transmission(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000006C1")!,
        startedAt: Date(timeIntervalSince1970: 5),
        endedAt: Date(timeIntervalSince1970: 9),
        text: "Runway two seven left, cleared to land"),
      to: summary.id)

    let transmissionsURL =
      root
      .appendingPathComponent(summary.id.uuidString, isDirectory: true)
      .appendingPathComponent("transmissions.jsonl", isDirectory: false)
    let handle = try FileHandle(forWritingTo: transmissionsURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"id\":\"torn".utf8))
    try handle.close()

    let lines = try store.exportJSONL(for: summary.id).split(separator: "\n")
    #expect(lines.count == 1)
    #expect(
      try Self.jsonObject(String(lines[0]))["text"] as? String
        == "Runway two seven left, cleared to land")
  }

  // MARK: - C7 session metadata (engine, duration, backward-compatible decode)

  @Test func summaryWithoutEngineFieldStillDecodes() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000007A1")!
    let directory = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // why: a pre-C7 summary has no engineDisplayName key — it must still load, with engine nil.
    let legacySummaryJSON = """
      {"endedAt":200,"id":"\(sessionID.uuidString)","localeIdentifier":"en-US","segmentCount":2,"startedAt":100}
      """
    try Data(legacySummaryJSON.utf8).write(
      to: directory.appendingPathComponent("summary.json", isDirectory: false))

    let store = try FileTranscriptStore(rootDirectory: root)
    let loaded = try store.sessions()
    #expect(loaded.count == 1)
    #expect(loaded.first?.id == sessionID)
    #expect(loaded.first?.engineDisplayName == nil)
    #expect(loaded.first?.durationSeconds == 100)
  }

  @Test func setEnginePersistsEngineOntoSummary() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let store = try FileTranscriptStore(rootDirectory: root) { Date(timeIntervalSince1970: 100) }
    let summary = try store.beginSession(localeIdentifier: "en-US")
    #expect(try store.sessions().first?.engineDisplayName == nil)

    try store.setEngine("WhisperKit", for: summary.id)

    let reopened = try FileTranscriptStore(rootDirectory: root)
    #expect(try reopened.sessions().first?.engineDisplayName == "WhisperKit")
  }

  @Test func durationSecondsIsNilForRecoveredSessionAndSetForEnded() throws {
    let open = TranscriptSessionSummary(
      id: UUID(), startedAt: Date(timeIntervalSince1970: 100), endedAt: nil,
      segmentCount: 0, localeIdentifier: "en-US")
    #expect(open.durationSeconds == nil)
    let ended = TranscriptSessionSummary(
      id: UUID(), startedAt: Date(timeIntervalSince1970: 100),
      endedAt: Date(timeIntervalSince1970: 142), segmentCount: 0, localeIdentifier: "en-US")
    #expect(ended.durationSeconds == 42)
  }

  // MARK: - C8 disk usage + retention cleanup

  @Test func totalDiskUsageIsZeroWhenEmptyAndGrowsWithSessions() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    let store = try FileTranscriptStore(rootDirectory: root) { Date(timeIntervalSince1970: 0) }
    #expect(store.totalDiskUsageBytes() == 0)
    let summary = try store.beginSession(localeIdentifier: "en-US")
    for segment in Self.segments() {
      try store.append(segment, to: summary.id)
    }
    try store.endSession(summary.id)
    #expect(store.totalDiskUsageBytes() > 0)
  }

  @Test func retentionCleanupDeletesOlderExcludesActiveAndKeepsBoundary() throws {
    let root = try Self.makeRoot()
    defer { Self.removeRoot(root) }
    var dates: [Date] = [
      Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 100),  // old ended
      Date(timeIntervalSince1970: 500), Date(timeIntervalSince1970: 1000),  // boundary ended
      Date(timeIntervalSince1970: 2000), Date(timeIntervalSince1970: 2000),  // recent ended
      Date(timeIntervalSince1970: 200),  // active (begin only)
    ]
    let store = try FileTranscriptStore(rootDirectory: root) { dates.removeFirst() }

    let old = try store.beginSession(localeIdentifier: "en-US")
    try store.endSession(old.id)
    let boundary = try store.beginSession(localeIdentifier: "en-US")
    try store.endSession(boundary.id)
    let recent = try store.beginSession(localeIdentifier: "en-US")
    try store.endSession(recent.id)
    let active = try store.beginSession(localeIdentifier: "en-US")

    let deleted = try store.deleteSessions(
      olderThan: Date(timeIntervalSince1970: 1000), excluding: active.id)

    #expect(deleted == 1)
    let remaining = Set(try store.sessions().map(\.id))
    #expect(!remaining.contains(old.id))
    #expect(remaining.contains(boundary.id))  // anchor exactly at window survives (strict <)
    #expect(remaining.contains(recent.id))
    #expect(remaining.contains(active.id))  // active never deleted
  }

  // MARK: - C8 retention settings (round-trip + corruption)

  final class InMemoryRetentionStorage: TranscriptRetentionStorage, @unchecked Sendable {
    var enabled: Bool?
    var window: TranscriptRetentionWindow?
    var issue: TranscriptRetentionStorageIssue?
    var failSaves = false
    func loadAutoCleanupEnabled() -> Bool { enabled ?? false }
    func saveAutoCleanupEnabled(_ enabled: Bool) throws {
      if failSaves { throw StoreFailure() }
      self.enabled = enabled
    }
    func loadRetentionWindow() -> TranscriptRetentionWindow { window ?? .days90 }
    func saveRetentionWindow(_ window: TranscriptRetentionWindow) throws {
      if failSaves { throw StoreFailure() }
      self.window = window
    }
    func loadIssue() -> TranscriptRetentionStorageIssue? { issue }
    struct StoreFailure: Error {}
  }

  @Test func retentionDefaultsOffAtNinetyDays() {
    let settings = TranscriptRetentionSettings(storage: InMemoryRetentionStorage())
    #expect(settings.autoCleanupEnabled == false)
    #expect(settings.window == .days90)
    #expect(settings.storageIssue == nil)
  }

  @Test func retentionUserDefaultsRoundTrip() throws {
    let suiteName = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storage = UserDefaultsTranscriptRetentionStorage(defaults: defaults)

    #expect(storage.loadAutoCleanupEnabled() == false)
    #expect(storage.loadRetentionWindow() == .days90)
    try storage.saveAutoCleanupEnabled(true)
    try storage.saveRetentionWindow(.days180)
    #expect(storage.loadAutoCleanupEnabled() == true)
    #expect(storage.loadRetentionWindow() == .days180)
    #expect(storage.loadIssue() == nil)
  }

  @Test func retentionUnknownWindowResolvesToDefaultAndFlagsCorruption() {
    let suiteName = "dspeech.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(45, forKey: UserDefaultsTranscriptRetentionStorage.windowKey)
    let storage = UserDefaultsTranscriptRetentionStorage(defaults: defaults)

    #expect(storage.loadRetentionWindow() == .days90)
    #expect(storage.loadIssue() == .retentionWindowCorrupted)
    let settings = TranscriptRetentionSettings(storage: storage)
    #expect(settings.window == .days90)
    #expect(settings.storageIssue == .retentionWindowCorrupted)
  }

  @Test func retentionSaveFailureSurfacesIssue() {
    let storage = InMemoryRetentionStorage()
    storage.failSaves = true
    let settings = TranscriptRetentionSettings(storage: storage)
    settings.autoCleanupEnabled = true
    #expect(settings.autoCleanupEnabled == true)
    #expect(storage.enabled == nil)
    #expect(settings.storageIssue == .autoCleanupSaveFailed)
    #expect(settings.hasStaleSettings)
  }

  private static func jsonObject(_ line: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
    guard let dictionary = object as? [String: Any] else {
      throw StoreTestError.notAnObject
    }
    return dictionary
  }

  enum StoreTestError: Error { case notAnObject }

  private static func segments() -> [TranscriptSegment] {
    [
      Self.segment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
        startedAt: Date(timeIntervalSince1970: 10),
        text: "November One Two Three Alpha Bravo, cleared direct"),
      Self.segment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
        startedAt: Date(timeIntervalSince1970: 20),
        text: "Descend and maintain three thousand",
        translatedText: "Descend and maintain three thousand translated",
        confidence: 0.77),
      Self.segment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
        startedAt: Date(timeIntervalSince1970: 30),
        text: "Contact approach one two four decimal six"),
    ]
  }

  private static func segment(
    id: UUID,
    startedAt: Date,
    text: String,
    translatedText: String? = nil,
    confidence: Double = 0.91,
    isStopCommittedPlaceholder: Bool = false
  ) -> TranscriptSegment {
    TranscriptSegment(
      id: id,
      startedAt: startedAt,
      text: text,
      translatedText: translatedText,
      confidence: confidence,
      sourceLanguageCode: "en",
      source: .liveATC,
      isStopCommittedPlaceholder: isStopCommittedPlaceholder
    )
  }

  private static func transmission(
    id: UUID,
    startedAt: Date,
    endedAt: Date,
    text: String
  ) -> Transmission {
    Transmission(
      id: id,
      startedAt: startedAt,
      endedAt: endedAt,
      text: text,
      segments: [
        Self.segment(
          id: id,
          startedAt: startedAt,
          text: text)
      ],
      classification: .displayed(.callSignMatch),
      localeIdentifier: "en-US"
    )
  }

  private static func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("dspeech-transcript-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private static func removeRoot(_ root: URL) {
    do {
      if FileManager.default.fileExists(atPath: root.path) {
        try FileManager.default.removeItem(at: root)
      }
    } catch {
      Issue.record("failed to remove fixture \(root.path): \(error)")
    }
  }
}
