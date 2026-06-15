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
