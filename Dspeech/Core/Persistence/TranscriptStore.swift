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
}

// why: the transcript is flight data (D4 in the 2026-06-11 spec). Losing it on app kill,
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
  private static let appDirectoryName = "Dspeech"
  private static let transcriptDirectoryName = "Transcripts"
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
      loaded.append(contentsOf: try decodeTransmissionLines(data, sessionID: sessionID))
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
    return Self.dedupedStopPlaceholders(try decodeSegmentLines(data, sessionID: sessionID))
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

  func corruptSessionIDs() -> [UUID] {
    corruptIDs
  }

  private static func defaultRootDirectory(fileManager: FileManager) throws -> URL {
    guard
      let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw TranscriptStoreError.ioFailure("Application Support directory is unavailable")
    }
    return
      applicationSupport
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

  private static func segment(from transmission: Transmission) -> TranscriptSegment {
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

  private func decodeSegmentLines(_ data: Data, sessionID: UUID) throws -> [TranscriptSegment] {
    guard !data.isEmpty else {
      return []
    }

    let endsWithNewline = data.last == Self.newline.first
    let lines = data.split(separator: Self.newline[0], omittingEmptySubsequences: false)
    var segments: [TranscriptSegment] = []
    segments.reserveCapacity(lines.count)

    for (index, line) in lines.enumerated() {
      if line.isEmpty && index == lines.count - 1 && endsWithNewline {
        continue
      }
      do {
        segments.append(try decoder.decode(TranscriptSegment.self, from: Data(line)))
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
    return segments
  }

  private func decodeTransmissionLines(_ data: Data, sessionID: UUID) throws -> [Transmission] {
    guard !data.isEmpty else {
      return []
    }

    let endsWithNewline = data.last == Self.newline.first
    let lines = data.split(separator: Self.newline[0], omittingEmptySubsequences: false)
    var transmissions: [Transmission] = []
    transmissions.reserveCapacity(lines.count)

    for (index, line) in lines.enumerated() {
      if line.isEmpty && index == lines.count - 1 && endsWithNewline {
        continue
      }
      do {
        transmissions.append(try decoder.decode(Transmission.self, from: Data(line)))
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
    return transmissions
  }

  private func segmentAppendHandle(for sessionID: UUID) throws -> FileHandle {
    if let handle = segmentAppendHandles[sessionID] {
      return handle
    }

    let fileURL = segmentsURL(for: sessionID)
    guard fileManager.fileExists(atPath: fileURL.path) else {
      throw TranscriptStoreError.ioFailure("Segments file is missing for \(sessionID)")
    }

    do {
      let handle = try FileHandle(forWritingTo: fileURL)
      try handle.seekToEnd()
      segmentAppendHandles[sessionID] = handle
      return handle
    } catch {
      throw TranscriptStoreError.ioFailure(error.localizedDescription)
    }
  }

  private func transmissionAppendHandle(for sessionID: UUID) throws -> FileHandle {
    if let handle = transmissionAppendHandles[sessionID] {
      return handle
    }

    let fileURL = transmissionsURL(for: sessionID)
    guard fileManager.fileExists(atPath: fileURL.path) else {
      throw TranscriptStoreError.ioFailure("Transmissions file is missing for \(sessionID)")
    }

    do {
      let handle = try FileHandle(forWritingTo: fileURL)
      try handle.seekToEnd()
      transmissionAppendHandles[sessionID] = handle
      return handle
    } catch {
      throw TranscriptStoreError.ioFailure(error.localizedDescription)
    }
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
