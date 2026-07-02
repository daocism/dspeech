import Foundation
import os

struct TranscriptSessionSummary: Identifiable, Equatable, Sendable, Codable {
  let id: UUID
  let startedAt: Date
  var endedAt: Date?
  // why: holds the TRANSMISSION (card) count, not raw ASR segments — the JSON key stays
  // `segmentCount` to avoid a persisted-summary migration; the UI labels it "transmissions".
  // Legacy sessions with no stored transmissions fall back to the segment count (see endSession).
  var segmentCount: Int
  let localeIdentifier: String
  // why: C7 — the recognition engine used for this session, surfaced in history. Optional +
  // additive so summaries persisted before this field keep decoding (synthesized decodeIfPresent
  // yields nil); a nil engine renders as a neutral "—" placeholder rather than a fabricated value.
  var engineDisplayName: String?

  // why: an explicit initializer (with an engineDisplayName default) keeps every existing
  // call site — which never passed an engine — compiling unchanged, while the synthesized
  // Codable conformance stays in place because no custom init(from:)/encode(to:) is provided.
  init(
    id: UUID,
    startedAt: Date,
    endedAt: Date?,
    segmentCount: Int,
    localeIdentifier: String,
    engineDisplayName: String? = nil
  ) {
    self.id = id
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.segmentCount = segmentCount
    self.localeIdentifier = localeIdentifier
    self.engineDisplayName = engineDisplayName
  }

  // why: honest duration — nil for a recovered session (no clean endedAt), so the UI shows "—"
  // instead of inventing an end time. Never negative if clocks disagree.
  var durationSeconds: TimeInterval? {
    guard let endedAt else { return nil }
    return max(0, endedAt.timeIntervalSince(startedAt))
  }
}

// why: the transcript is flight data (spec item D4). Losing it on app kill,
// jetsam, or crash is data loss, so every finalized segment is WRITTEN as it arrives (the
// bytes survive app-kill/jetsam/crash via the page cache, and recovery tolerates a torn tail).
// Durability against power-loss/panic is checkpointed — not per-append — via flush() (wired to
// the background hook) and endSession, so appends never fsync on the MainActor render path.
@MainActor
protocol TranscriptStoring {
  @discardableResult
  func beginSession(localeIdentifier: String) throws -> TranscriptSessionSummary
  func append(_ segment: TranscriptSegment, to sessionID: UUID) throws
  func updateOpen(_ transmission: Transmission, in sessionID: UUID) throws
  func append(_ transmission: Transmission, to sessionID: UUID) throws
  func endSession(_ sessionID: UUID) throws
  // why: fsync the active session's open handles at a checkpoint (app backgrounding) so the
  // page-cache-durable appends also survive power-loss/panic, without an fsync per append.
  func flush() throws
  func sessions() throws -> [TranscriptSessionSummary]
  func segments(in sessionID: UUID) throws -> [TranscriptSegment]
  func transmissions(in sessionID: UUID) throws -> [Transmission]
  func deleteSession(_ sessionID: UUID) throws
  func exportText(for sessionID: UUID) throws -> String
  // why: C6 — structured, one-object-per-line export alongside the plain-text share, built from
  // the same torn-tail-tolerant row readers. C7 — records the engine used onto the open session.
  // Both ship a default (below) so existing test doubles conform without change.
  func exportJSONL(for sessionID: UUID) throws -> String
  func setEngine(_ engineDisplayName: String, for sessionID: UUID) throws
  @discardableResult
  func deleteSessions(olderThan cutoff: Date, excluding activeSessionID: UUID?) throws -> Int
}

extension TranscriptStoring {
  // why: default over the PUBLIC row readers so any conformer (incl. test doubles) gets a valid
  // JSONL export without reimplementing it. FileTranscriptStore overrides to also stamp the
  // session's persisted engine, which the public surface doesn't expose.
  func exportJSONL(for sessionID: UUID) throws -> String {
    let transmissionRows = try transmissions(in: sessionID)
    if !transmissionRows.isEmpty {
      return try TranscriptJSONL.encode(
        transmissions: transmissionRows, engineDisplayName: nil)
    }
    return try TranscriptJSONL.encode(
      segments: try segments(in: sessionID), engineDisplayName: nil)
  }

  // why: recording the engine is a persistence concern; a test double that doesn't persist
  // summaries has nothing to record, so the default is intentionally a no-op.
  func setEngine(_ engineDisplayName: String, for sessionID: UUID) throws {}

  // why: retention cleanup only means something for a store with durable sessions; doubles
  // report zero deletions.
  @discardableResult
  func deleteSessions(olderThan cutoff: Date, excluding activeSessionID: UUID?) throws -> Int { 0 }
}

// why: pure JSONL encoder — one self-describing JSON object per line, sorted keys for a stable
// golden shape. Optional fields (end, engine, classification) are omitted when absent rather than
// emitted as null, so a legacy segment and a rich transmission stay unambiguous. No I/O here.
enum TranscriptJSONL {
  struct Row: Encodable {
    let confidence: Double
    let end: TimeInterval?
    let engine: String?
    let id: String
    let kind: String?
    let reason: String?
    let sourceLanguage: String
    let start: TimeInterval
    let text: String

    enum CodingKeys: String, CodingKey {
      case confidence, end, engine, id, kind, reason, sourceLanguage, start, text
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(confidence, forKey: .confidence)
      try container.encodeIfPresent(end, forKey: .end)
      try container.encodeIfPresent(engine, forKey: .engine)
      try container.encode(id, forKey: .id)
      try container.encodeIfPresent(kind, forKey: .kind)
      try container.encodeIfPresent(reason, forKey: .reason)
      try container.encode(sourceLanguage, forKey: .sourceLanguage)
      try container.encode(start, forKey: .start)
      try container.encode(text, forKey: .text)
    }
  }

  static func encode(transmissions: [Transmission], engineDisplayName: String?) throws -> String {
    try transmissions.map { transmission in
      let segment = FileTranscriptStore.segment(from: transmission)
      let (kind, reason) = classificationParts(transmission.classification)
      return try line(
        Row(
          confidence: segment.confidence,
          end: transmission.endedAt.timeIntervalSince1970,
          engine: engineDisplayName,
          id: transmission.id.uuidString,
          kind: kind,
          reason: reason,
          sourceLanguage: segment.sourceLanguageCode,
          start: transmission.startedAt.timeIntervalSince1970,
          text: transmission.text
        ))
    }
    .joined(separator: "\n")
  }

  static func encode(segments: [TranscriptSegment], engineDisplayName: String?) throws -> String {
    try segments.map { segment in
      try line(
        Row(
          confidence: segment.confidence,
          end: nil,
          engine: engineDisplayName,
          id: segment.id.uuidString,
          kind: nil,
          reason: nil,
          sourceLanguage: segment.sourceLanguageCode,
          start: segment.startedAt.timeIntervalSince1970,
          text: segment.text
        ))
    }
    .joined(separator: "\n")
  }

  private static func classificationParts(
    _ classification: TransmissionClassification
  ) -> (kind: String, reason: String) {
    switch classification {
    case .displayed(let reason):
      return ("displayed", reason.rawValue)
    case .filtered(let reason):
      return ("filtered", reason.rawValue)
    }
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  private static func line(_ row: Row) throws -> String {
    let data = try encoder.encode(row)
    guard let string = String(data: data, encoding: .utf8) else {
      throw TranscriptStoreError.encodingFailure("JSONL row was not valid UTF-8")
    }
    return string
  }
}

enum TranscriptStoreError: LocalizedError, Equatable {
  case unknownSession(UUID)
  case encodingFailure(String)
  case decodingFailure(sessionID: UUID, line: Int?, underlyingDescription: String)
  case ioFailure(String)

  var errorDescription: String? {
    switch self {
    case .unknownSession:
      String(localized: "Transcript session was not found.")
    case .encodingFailure(let underlyingDescription):
      String(localized: "Transcript encoding failed: \(underlyingDescription)")
    case .decodingFailure(_, _, let underlyingDescription):
      String(localized: "Transcript decoding failed: \(underlyingDescription)")
    case .ioFailure(let underlyingDescription):
      String(localized: "Transcript storage failed: \(underlyingDescription)")
    }
  }
}

@MainActor
final class FileTranscriptStore: TranscriptStoring {
  nonisolated private static let appDirectoryName = "Dspeech"
  nonisolated private static let transcriptDirectoryName = "Transcripts"
  private static let summaryFileName = "summary.json"
  private static let segmentsFileName = "segments.jsonl"
  private static let transmissionsFileName = "transmissions.jsonl"
  private static let openTransmissionFileName = "open-transmission.json"
  private static let newline = Data([0x0A])

  private let rootDirectory: URL
  private let fileManager: FileManager
  private let now: () -> Date
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private var segmentAppendHandles: [UUID: FileHandle] = [:]
  private var transmissionAppendHandles: [UUID: FileHandle] = [:]
  private var corruptIDs: [UUID] = []

  init(
    rootDirectory: URL? = nil,
    fileManager: FileManager = .default,
    now: @escaping () -> Date = { Date() }
  ) throws {
    self.fileManager = fileManager
    self.now = now
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    if let rootDirectory {
      self.rootDirectory = rootDirectory
    } else {
      self.rootDirectory = try Self.defaultRootDirectory(fileManager: fileManager)
    }
    try createDirectoryWithProtection(at: self.rootDirectory)
  }

  @discardableResult
  func beginSession(localeIdentifier: String) throws -> TranscriptSessionSummary {
    let summary = TranscriptSessionSummary(
      id: UUID(),
      startedAt: now(),
      endedAt: nil,
      segmentCount: 0,
      localeIdentifier: localeIdentifier
    )
    let sessionDirectory = sessionDirectory(for: summary.id)
    try createDirectoryWithProtection(at: sessionDirectory)
    try writeSummary(summary)
    try createSegmentsFileIfMissing(for: summary.id)
    _ = try segmentAppendHandle(for: summary.id)
    DspeechLog.persistence.info(
      "transcript session began id=\(summary.id.uuidString, privacy: .public) locale=\(localeIdentifier, privacy: .public)"
    )
    return summary
  }

  func append(_ segment: TranscriptSegment, to sessionID: UUID) throws {
    do {
      try ensureSessionExists(sessionID)
      let line = try encodeSegmentLine(segment)
      let handle = try segmentAppendHandle(for: sessionID)
      try handle.write(contentsOf: line)
      try handle.write(contentsOf: Self.newline)
    } catch let error as TranscriptStoreError {
      logAppendFailure(sessionID: sessionID, error: error)
      throw error
    } catch {
      let wrapped = TranscriptStoreError.ioFailure(error.localizedDescription)
      logAppendFailure(sessionID: sessionID, error: wrapped)
      throw wrapped
    }
  }

  func updateOpen(_ transmission: Transmission, in sessionID: UUID) throws {
    do {
      try ensureSessionExists(sessionID)
      let data = try encodeTransmissionLine(transmission)
      let fileURL = openTransmissionURL(for: sessionID)
      // why: NOT .atomic — the open-transmission scratch is a best-effort live snapshot rewritten
      // every ~500ms; .atomic implies a per-tick fsync on the MainActor. A non-atomic write can be
      // torn by a crash, but transmissions() skips an undecodable scratch and the CLOSED log is the
      // durable record, so atomicity buys nothing here worth the recurring main-thread stall.
      try data.write(to: fileURL)
      try applyProtection(to: fileURL)
    } catch let error as TranscriptStoreError {
      logAppendFailure(sessionID: sessionID, error: error)
      throw error
    } catch {
      let wrapped = TranscriptStoreError.ioFailure(error.localizedDescription)
      logAppendFailure(sessionID: sessionID, error: wrapped)
      throw wrapped
    }
  }

  func append(_ transmission: Transmission, to sessionID: UUID) throws {
    do {
      try ensureSessionExists(sessionID)
      try createTransmissionsFileIfMissing(for: sessionID)
      let line = try encodeTransmissionLine(transmission)
      let handle = try transmissionAppendHandle(for: sessionID)
      try handle.write(contentsOf: line)
      try handle.write(contentsOf: Self.newline)
      try removeOpenTransmissionIfPresent(for: sessionID)
    } catch let error as TranscriptStoreError {
      logAppendFailure(sessionID: sessionID, error: error)
      throw error
    } catch {
      let wrapped = TranscriptStoreError.ioFailure(error.localizedDescription)
      logAppendFailure(sessionID: sessionID, error: wrapped)
      throw wrapped
    }
  }

  func endSession(_ sessionID: UUID) throws {
    var summary = try readSummary(for: sessionID)
    if let handle = segmentAppendHandles[sessionID] {
      try handle.synchronize()
    }
    if let handle = transmissionAppendHandles[sessionID] {
      try handle.synchronize()
    }
    summary.endedAt = now()
    let storedTransmissions = try transmissions(in: sessionID)
    summary.segmentCount =
      storedTransmissions.isEmpty
      ? try legacySegments(in: sessionID).count
      : storedTransmissions.count
    try writeSummary(summary)
    try closeAppendHandle(for: sessionID)
    DspeechLog.persistence.info(
      "transcript session ended id=\(sessionID.uuidString, privacy: .public) segmentCount=\(summary.segmentCount, privacy: .public)"
    )
  }

  // why: B's durability checkpoint — fsync the open append handles so the page-cache-durable
  // per-append writes also survive power-loss/panic, called from the app's background hook rather
  // than per append. No-op when no session is open (empty handle maps).
  func flush() throws {
    do {
      for handle in segmentAppendHandles.values { try handle.synchronize() }
      for handle in transmissionAppendHandles.values { try handle.synchronize() }
    } catch {
      throw TranscriptStoreError.ioFailure(error.localizedDescription)
    }
  }

  func sessions() throws -> [TranscriptSessionSummary] {
    corruptIDs = []
    let directories: [URL]
    do {
      directories = try fileManager.contentsOfDirectory(
        at: rootDirectory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      throw TranscriptStoreError.ioFailure(error.localizedDescription)
    }

    var summaries: [TranscriptSessionSummary] = []
    for directory in directories {
      guard let sessionID = UUID(uuidString: directory.lastPathComponent) else {
        continue
      }
      do {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
          corruptIDs.append(sessionID)
          continue
        }
        let summary = try readSummary(for: sessionID)
        guard summary.id == sessionID else {
          corruptIDs.append(sessionID)
          continue
        }
        summaries.append(summary)
      } catch {
        corruptIDs.append(sessionID)
      }
    }

    corruptIDs.sort { $0.uuidString < $1.uuidString }
    return summaries.sorted { lhs, rhs in
      if lhs.startedAt == rhs.startedAt {
        lhs.id.uuidString > rhs.id.uuidString
      } else {
        lhs.startedAt > rhs.startedAt
      }
    }
  }

  func segments(in sessionID: UUID) throws -> [TranscriptSegment] {
    let storedTransmissions = try transmissions(in: sessionID)
    if !storedTransmissions.isEmpty {
      return storedTransmissions.map(Self.segment(from:))
    }
    return try legacySegments(in: sessionID)
  }

  func transmissions(in sessionID: UUID) throws -> [Transmission] {
    try ensureSessionExists(sessionID)
    var loaded: [Transmission] = []
    if fileManager.fileExists(atPath: transmissionsURL(for: sessionID).path) {
      let data: Data
      do {
        data = try Data(contentsOf: transmissionsURL(for: sessionID))
      } catch {
        throw TranscriptStoreError.ioFailure(error.localizedDescription)
      }
      let decoded: [Transmission] = try decodeLines(data, sessionID: sessionID)
      loaded.append(contentsOf: decoded)
    }
    if fileManager.fileExists(atPath: openTransmissionURL(for: sessionID).path) {
      let data: Data
      do {
        data = try Data(contentsOf: openTransmissionURL(for: sessionID))
      } catch {
        throw TranscriptStoreError.ioFailure(error.localizedDescription)
      }
      do {
        let open = try decoder.decode(Transmission.self, from: data)
        if !loaded.contains(where: { $0.id == open.id }) {
          loaded.append(open)
        }
      } catch {
        // why: the scratch is a best-effort live snapshot written without atomicity, so a crash
        // mid-write can leave it torn (invalid JSON). Skip an undecodable scratch — the CLOSED
        // transmissions are the durable record; never fail the whole session read on a torn scratch.
        DspeechLog.persistence.error(
          "open-transmission scratch undecodable; skipping id=\(sessionID.uuidString, privacy: .public)"
        )
      }
    }
    return loaded
  }

  private func legacySegments(in sessionID: UUID) throws -> [TranscriptSegment] {
    try ensureSessionExists(sessionID)
    let fileURL = segmentsURL(for: sessionID)
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      throw TranscriptStoreError.ioFailure(error.localizedDescription)
    }
    let decoded: [TranscriptSegment] = try decodeLines(data, sessionID: sessionID)
    return Self.dedupedStopPlaceholders(decoded)
  }

  func deleteSession(_ sessionID: UUID) throws {
    try ensureSessionExists(sessionID)
    try closeAppendHandle(for: sessionID)
    do {
      try fileManager.removeItem(at: sessionDirectory(for: sessionID))
    } catch {
      throw TranscriptStoreError.ioFailure(error.localizedDescription)
    }
    DspeechLog.persistence.info(
      "transcript session deleted id=\(sessionID.uuidString, privacy: .public)"
    )
  }

  func exportText(for sessionID: UUID) throws -> String {
    let summary = try readSummary(for: sessionID)
    let transmissionRows = try transmissions(in: sessionID)
    let lines: [String]
    if !transmissionRows.isEmpty {
      lines = transmissionRows.map { transmission in
        "\(Self.timeString(from: transmission.startedAt))  \(transmission.text)"
      }
    } else {
      lines = try legacySegments(in: sessionID).map { segment in
        "\(Self.timeString(from: segment.startedAt))  \(segment.text)"
      }
    }
    return
      ([
        "Dspeech transcript  \(Self.dateString(from: summary.startedAt))  \(summary.localeIdentifier)"
      ] + lines)
      .joined(separator: "\n")
  }

  // why: C6 — the structured export mirrors exportText's row selection (transmissions first,
  // legacy segments as fallback) but stamps the persisted engine onto each line, which the public
  // protocol surface can't reach. Same torn-tail tolerance because it reuses transmissions()/legacy.
  func exportJSONL(for sessionID: UUID) throws -> String {
    let summary = try readSummary(for: sessionID)
    let transmissionRows = try transmissions(in: sessionID)
    if !transmissionRows.isEmpty {
      return try TranscriptJSONL.encode(
        transmissions: transmissionRows, engineDisplayName: summary.engineDisplayName)
    }
    return try TranscriptJSONL.encode(
      segments: try legacySegments(in: sessionID), engineDisplayName: summary.engineDisplayName)
  }

  // why: C7 — the coordinator stamps the engine onto the OPEN session once at start; it is not a
  // beginSession parameter so the persisted-summary shape stays additive. Rewrites the summary
  // atomically (writeSummary uses .atomic) alongside the same protection level.
  func setEngine(_ engineDisplayName: String, for sessionID: UUID) throws {
    var summary = try readSummary(for: sessionID)
    summary.engineDisplayName = engineDisplayName
    try writeSummary(summary)
  }

  // why: C8 — total on-disk footprint of the transcript store, summed over regular files only
  // (directory entries carry their own allocation the app doesn't own). Instance form is used by
  // tests with a custom root; Settings uses the static self-resolving form off the main actor.
  func totalDiskUsageBytes() -> Int64 {
    Self.directoryByteCount(at: rootDirectory, fileManager: fileManager)
  }

  // why: C8 — a static entry point for surfaces (Settings) that don't hold a store instance; it
  // self-resolves the same default root the store uses. Returns 0 when the directory is absent.
  nonisolated static func totalDiskUsageBytes(fileManager: FileManager = .default) -> Int64 {
    guard let root = try? defaultRootDirectory(fileManager: fileManager),
      fileManager.fileExists(atPath: root.path)
    else {
      return 0
    }
    return directoryByteCount(at: root, fileManager: fileManager)
  }

  nonisolated private static func directoryByteCount(at url: URL, fileManager: FileManager) -> Int64
  {
    guard
      let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
        options: []
      )
    else {
      return 0
    }
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
        values.isRegularFile == true
      else {
        continue
      }
      total += Int64(values.fileSize ?? 0)
    }
    return total
  }

  // why: C8 — opt-in retention cleanup. Deletes WHOLE sessions whose age anchor precedes the
  // cutoff, never the active session, and never a session exactly at the window (strict <, so a
  // session aged exactly the retention window survives one more launch). Returns the count deleted
  // for an honest log. Age anchor = endedAt when the flight closed cleanly, else startedAt.
  @discardableResult
  func deleteSessions(olderThan cutoff: Date, excluding activeSessionID: UUID? = nil) throws -> Int
  {
    let summaries = try sessions()
    var deletedCount = 0
    for summary in summaries {
      if summary.id == activeSessionID { continue }
      let ageAnchor = summary.endedAt ?? summary.startedAt
      guard ageAnchor < cutoff else { continue }
      try deleteSession(summary.id)
      deletedCount += 1
    }
    DspeechLog.persistence.info(
      "retention cleanup deleted count=\(deletedCount, privacy: .public) cutoff=\(cutoff.timeIntervalSince1970, privacy: .public)"
    )
    return deletedCount
  }

  func corruptSessionIDs() -> [UUID] {
    corruptIDs
  }

  nonisolated private static func defaultRootDirectory(fileManager: FileManager) throws -> URL {
    try ApplicationSupport.directory(fileManager: fileManager)
      .appendingPathComponent(appDirectoryName, isDirectory: true)
      .appendingPathComponent(transcriptDirectoryName, isDirectory: true)
  }

  private static func dateString(from date: Date) -> String {
    Self.dateFormatter().string(from: date)
  }

  private static func timeString(from date: Date) -> String {
    Self.timeFormatter().string(from: date)
  }

  private static func dateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }

  private static func timeFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }

  private static func dedupedStopPlaceholders(
    _ segments: [TranscriptSegment]
  ) -> [TranscriptSegment] {
    guard segments.count > 1 else { return segments }
    var deduped: [TranscriptSegment] = []
    deduped.reserveCapacity(segments.count)
    for index in segments.indices {
      let segment = segments[index]
      if index < segments.index(before: segments.endIndex) {
        let next = segments[segments.index(after: index)]
        if segment.source == .liveATC,
          segment.isStopCommittedPlaceholder,
          next.source == .liveATC,
          !next.isStopCommittedPlaceholder,
          segment.text.caseInsensitiveCompare(next.text) == .orderedSame
        {
          continue
        }
      }
      deduped.append(segment)
    }
    return deduped
  }

  nonisolated static func segment(from transmission: Transmission) -> TranscriptSegment {
    let sourceLanguageCode =
      transmission.segments.first?.sourceLanguageCode
      ?? Locale(identifier: transmission.localeIdentifier).language.languageCode?.identifier
      ?? transmission.localeIdentifier
    let source = transmission.segments.first?.source ?? .liveATC
    let confidenceValues = transmission.segments.map(\.confidence).filter { $0 > 0 }
    let confidence =
      confidenceValues.isEmpty
      ? 0
      : confidenceValues.reduce(0, +) / Double(confidenceValues.count)
    return TranscriptSegment(
      id: transmission.id,
      startedAt: transmission.startedAt,
      text: transmission.text,
      confidence: confidence,
      sourceLanguageCode: sourceLanguageCode,
      source: source,
      isStopCommittedPlaceholder: transmission.segments.contains {
        $0.isStopCommittedPlaceholder
      },
      isInterimRestartCommit: transmission.segments.contains {
        $0.isInterimRestartCommit
      }
    )
  }

  private func sessionDirectory(for sessionID: UUID) -> URL {
    rootDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
  }

  private func summaryURL(for sessionID: UUID) -> URL {
    sessionDirectory(for: sessionID)
      .appendingPathComponent(Self.summaryFileName, isDirectory: false)
  }

  private func segmentsURL(for sessionID: UUID) -> URL {
    sessionDirectory(for: sessionID)
      .appendingPathComponent(Self.segmentsFileName, isDirectory: false)
  }

  private func transmissionsURL(for sessionID: UUID) -> URL {
    sessionDirectory(for: sessionID)
      .appendingPathComponent(Self.transmissionsFileName, isDirectory: false)
  }

  private func openTransmissionURL(for sessionID: UUID) -> URL {
    sessionDirectory(for: sessionID)
      .appendingPathComponent(Self.openTransmissionFileName, isDirectory: false)
  }

  private func ensureSessionExists(_ sessionID: UUID) throws {
    guard fileManager.fileExists(atPath: summaryURL(for: sessionID).path) else {
      throw TranscriptStoreError.unknownSession(sessionID)
    }
  }

  private func createDirectoryWithProtection(at url: URL) throws {
    do {
      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
      try applyProtection(to: url)
    } catch let error as TranscriptStoreError {
      throw error
    } catch {
      throw TranscriptStoreError.ioFailure(error.localizedDescription)
    }
  }

  private func createSegmentsFileIfMissing(for sessionID: UUID) throws {
    let fileURL = segmentsURL(for: sessionID)
    guard !fileManager.fileExists(atPath: fileURL.path) else {
      try applyProtection(to: fileURL)
      return
    }
    guard fileManager.createFile(atPath: fileURL.path, contents: Data()) else {
      throw TranscriptStoreError.ioFailure("Could not create segments file for \(sessionID)")
    }
    try applyProtection(to: fileURL)
  }

  private func createTransmissionsFileIfMissing(for sessionID: UUID) throws {
    let fileURL = transmissionsURL(for: sessionID)
    guard !fileManager.fileExists(atPath: fileURL.path) else {
      try applyProtection(to: fileURL)
      return
    }
    guard fileManager.createFile(atPath: fileURL.path, contents: Data()) else {
      throw TranscriptStoreError.ioFailure("Could not create transmissions file for \(sessionID)")
    }
    try applyProtection(to: fileURL)
  }

  private func applyProtection(to url: URL) throws {
    // why: flight data must stay appendable while the device is locked during an ADR-0010
    // keep-awake session, so .complete (voiceprints' level) is too strict; per-append flush
    // precludes holding an open handle, so .completeUnlessOpen isn't viable either.
    do {
      try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path
      )
    } catch {
      throw TranscriptStoreError.ioFailure(error.localizedDescription)
    }
  }

  private func writeSummary(_ summary: TranscriptSessionSummary) throws {
    let data: Data
    do {
      data = try encoder.encode(summary)
    } catch {
      throw TranscriptStoreError.encodingFailure(error.localizedDescription)
    }

    do {
      try data.write(to: summaryURL(for: summary.id), options: .atomic)
      try applyProtection(to: summaryURL(for: summary.id))
    } catch let error as TranscriptStoreError {
      throw error
    } catch {
      throw TranscriptStoreError.ioFailure(error.localizedDescription)
    }
  }

  private func readSummary(for sessionID: UUID) throws -> TranscriptSessionSummary {
    let fileURL = summaryURL(for: sessionID)
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      if fileManager.fileExists(atPath: sessionDirectory(for: sessionID).path) {
        throw TranscriptStoreError.decodingFailure(
          sessionID: sessionID,
          line: nil,
          underlyingDescription: error.localizedDescription
        )
      }
      throw TranscriptStoreError.unknownSession(sessionID)
    }

    do {
      return try decoder.decode(TranscriptSessionSummary.self, from: data)
    } catch {
      throw TranscriptStoreError.decodingFailure(
        sessionID: sessionID,
        line: nil,
        underlyingDescription: error.localizedDescription
      )
    }
  }

  private func encodeSegmentLine(_ segment: TranscriptSegment) throws -> Data {
    do {
      return try encoder.encode(segment)
    } catch {
      throw TranscriptStoreError.encodingFailure(error.localizedDescription)
    }
  }

  private func encodeTransmissionLine(_ transmission: Transmission) throws -> Data {
    do {
      return try encoder.encode(transmission)
    } catch {
      throw TranscriptStoreError.encodingFailure(error.localizedDescription)
    }
  }

  // why: JSONL decode is generic in the row type — segments and transmissions share the same
  // file layout (newline-delimited JSON, torn-tail tolerance). Keeping one implementation rules
  // out asymmetric drift between the two readers.
  private func decodeLines<Row: Decodable>(_ data: Data, sessionID: UUID) throws -> [Row] {
    guard !data.isEmpty else {
      return []
    }

    let endsWithNewline = data.last == Self.newline.first
    let lines = data.split(separator: Self.newline[0], omittingEmptySubsequences: false)
    var rows: [Row] = []
    rows.reserveCapacity(lines.count)

    for (index, line) in lines.enumerated() {
      if line.isEmpty && index == lines.count - 1 && endsWithNewline {
        continue
      }
      do {
        rows.append(try decoder.decode(Row.self, from: Data(line)))
      } catch {
        if index == lines.count - 1 && !endsWithNewline {
          continue
        }
        throw TranscriptStoreError.decodingFailure(
          sessionID: sessionID,
          line: index + 1,
          underlyingDescription: error.localizedDescription
        )
      }
    }
    return rows
  }

  // why: opening a write-to-end FileHandle has the same shape for segments and transmissions —
  // exists check + writer + seekToEnd + uniform ioFailure mapping. Per-row cache management
  // stays in the call sites so the two row kinds keep their own caches.
  private func openAppendHandle(at fileURL: URL, missingMessage: @autoclosure () -> String)
    throws -> FileHandle
  {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      throw TranscriptStoreError.ioFailure(missingMessage())
    }
    do {
      let handle = try FileHandle(forWritingTo: fileURL)
      try handle.seekToEnd()
      return handle
    } catch {
      throw TranscriptStoreError.ioFailure(error.localizedDescription)
    }
  }

  private func segmentAppendHandle(for sessionID: UUID) throws -> FileHandle {
    if let handle = segmentAppendHandles[sessionID] {
      return handle
    }
    let handle = try openAppendHandle(
      at: segmentsURL(for: sessionID),
      missingMessage: "Segments file is missing for \(sessionID)")
    segmentAppendHandles[sessionID] = handle
    return handle
  }

  private func transmissionAppendHandle(for sessionID: UUID) throws -> FileHandle {
    if let handle = transmissionAppendHandles[sessionID] {
      return handle
    }
    let handle = try openAppendHandle(
      at: transmissionsURL(for: sessionID),
      missingMessage: "Transmissions file is missing for \(sessionID)")
    transmissionAppendHandles[sessionID] = handle
    return handle
  }

  private func closeAppendHandle(for sessionID: UUID) throws {
    let handles = [
      segmentAppendHandles.removeValue(forKey: sessionID),
      transmissionAppendHandles.removeValue(forKey: sessionID),
    ].compactMap { $0 }
    for handle in handles {
      do {
        try handle.synchronize()
        try handle.close()
      } catch {
        throw TranscriptStoreError.ioFailure(error.localizedDescription)
      }
    }
  }

  private func removeOpenTransmissionIfPresent(for sessionID: UUID) throws {
    let fileURL = openTransmissionURL(for: sessionID)
    guard fileManager.fileExists(atPath: fileURL.path) else { return }
    do {
      try fileManager.removeItem(at: fileURL)
    } catch {
      throw TranscriptStoreError.ioFailure(error.localizedDescription)
    }
  }

  private func logAppendFailure(sessionID: UUID, error: TranscriptStoreError) {
    DspeechLog.persistence.error(
      "transcript append failed id=\(sessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
    )
  }
}

// MARK: - C8 retention settings (opt-in auto-cleanup of old sessions)

// why: the retention window is a closed set of honest choices, not a free integer — modelling it as
// an enum makes an out-of-range persisted value detectable (corruption) instead of silently applied.
enum TranscriptRetentionWindow: Int, CaseIterable, Sendable, Codable, Identifiable {
  case days30 = 30
  case days90 = 90
  case days180 = 180

  var id: Int { rawValue }
  var days: Int { rawValue }
}

enum TranscriptRetentionStorageIssue: Equatable, Sendable {
  case retentionWindowCorrupted
  case autoCleanupSaveFailed
  case retentionWindowSaveFailed
}

// why: mirrors the PrivacySettings storage-protocol template — a Sendable storage seam so the
// @Observable model stays a pure value holder and persistence is injectable for round-trip +
// corruption tests.
protocol TranscriptRetentionStorage: Sendable {
  func loadAutoCleanupEnabled() -> Bool
  func saveAutoCleanupEnabled(_ enabled: Bool) throws
  func loadRetentionWindow() -> TranscriptRetentionWindow
  func saveRetentionWindow(_ window: TranscriptRetentionWindow) throws
  func loadIssue() -> TranscriptRetentionStorageIssue?
}

extension TranscriptRetentionStorage {
  func loadIssue() -> TranscriptRetentionStorageIssue? { nil }
}

struct UserDefaultsTranscriptRetentionStorage: TranscriptRetentionStorage, @unchecked Sendable {
  static let autoCleanupKey = "dspeech.retention.autocleanup.v1"
  static let windowKey = "dspeech.retention.window.days.v1"
  // why: default window when none was ever chosen. Only takes effect once auto-cleanup is enabled
  // (which defaults OFF), so no flight is ever deleted without an explicit opt-in.
  static let defaultWindow: TranscriptRetentionWindow = .days90

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func loadAutoCleanupEnabled() -> Bool {
    (defaults.object(forKey: Self.autoCleanupKey) as? Bool) ?? false
  }

  func saveAutoCleanupEnabled(_ enabled: Bool) throws {
    defaults.set(enabled, forKey: Self.autoCleanupKey)
  }

  func loadRetentionWindow() -> TranscriptRetentionWindow {
    guard defaults.object(forKey: Self.windowKey) != nil else { return Self.defaultWindow }
    return TranscriptRetentionWindow(rawValue: defaults.integer(forKey: Self.windowKey))
      ?? Self.defaultWindow
  }

  func saveRetentionWindow(_ window: TranscriptRetentionWindow) throws {
    defaults.set(window.rawValue, forKey: Self.windowKey)
  }

  func loadIssue() -> TranscriptRetentionStorageIssue? {
    guard defaults.object(forKey: Self.windowKey) != nil else { return nil }
    return TranscriptRetentionWindow(rawValue: defaults.integer(forKey: Self.windowKey)) == nil
      ? .retentionWindowCorrupted : nil
  }
}

@MainActor
@Observable
final class TranscriptRetentionSettings {
  private let storage: TranscriptRetentionStorage
  private(set) var storageIssue: TranscriptRetentionStorageIssue?
  var hasStaleSettings: Bool { storageIssue != nil }

  var autoCleanupEnabled: Bool {
    didSet {
      guard autoCleanupEnabled != oldValue else { return }
      do {
        try storage.saveAutoCleanupEnabled(autoCleanupEnabled)
        storageIssue = nil
      } catch {
        storageIssue = .autoCleanupSaveFailed
      }
    }
  }

  var window: TranscriptRetentionWindow {
    didSet {
      guard window != oldValue else { return }
      do {
        try storage.saveRetentionWindow(window)
        storageIssue = nil
      } catch {
        storageIssue = .retentionWindowSaveFailed
      }
    }
  }

  init(storage: TranscriptRetentionStorage = UserDefaultsTranscriptRetentionStorage()) {
    self.storage = storage
    self.autoCleanupEnabled = storage.loadAutoCleanupEnabled()
    self.window = storage.loadRetentionWindow()
    self.storageIssue = storage.loadIssue()
  }
}
