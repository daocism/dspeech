import Foundation
import os

struct TranscriptSessionSummary: Identifiable, Equatable, Sendable, Codable {
  let id: UUID
  let startedAt: Date
  var endedAt: Date?
  var segmentCount: Int
  let localeIdentifier: String
}

// why: the transcript is flight data (D4 in the 2026-06-11 spec). Losing it on app kill,
// jetsam, or crash is data loss, so every finalized segment is persisted as it arrives and
// sessions are recoverable after relaunch. Implementations must be safe to call on every
// ASR final without blocking the MainActor render path.
@MainActor
protocol TranscriptStoring {
  @discardableResult
  func beginSession(localeIdentifier: String) throws -> TranscriptSessionSummary
  func append(_ segment: TranscriptSegment, to sessionID: UUID) throws
  func endSession(_ sessionID: UUID) throws
  func sessions() throws -> [TranscriptSessionSummary]
  func segments(in sessionID: UUID) throws -> [TranscriptSegment]
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
  private static let newline = Data([0x0A])

  private let rootDirectory: URL
  private let fileManager: FileManager
  private let now: () -> Date
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private var appendHandles: [UUID: FileHandle] = [:]
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
    _ = try appendHandle(for: summary.id)
    DspeechLog.persistence.info(
      "transcript session began id=\(summary.id.uuidString, privacy: .public) locale=\(localeIdentifier, privacy: .public)"
    )
    return summary
  }

  func append(_ segment: TranscriptSegment, to sessionID: UUID) throws {
    do {
      try ensureSessionExists(sessionID)
      let line = try encodeSegmentLine(segment)
      let handle = try appendHandle(for: sessionID)
      try handle.write(contentsOf: line)
      try handle.write(contentsOf: Self.newline)
      try handle.synchronize()
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
    if let handle = appendHandles[sessionID] {
      try handle.synchronize()
    }
    summary.endedAt = now()
    summary.segmentCount = try segments(in: sessionID).count
    try writeSummary(summary)
    try closeAppendHandle(for: sessionID)
    DspeechLog.persistence.info(
      "transcript session ended id=\(sessionID.uuidString, privacy: .public) segmentCount=\(summary.segmentCount, privacy: .public)"
    )
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
    let lines = try segments(in: sessionID).map { segment in
      "\(Self.timeString(from: segment.startedAt))  \(segment.text)"
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

  private func applyProtection(to url: URL) throws {
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

  private func appendHandle(for sessionID: UUID) throws -> FileHandle {
    if let handle = appendHandles[sessionID] {
      return handle
    }

    let fileURL = segmentsURL(for: sessionID)
    guard fileManager.fileExists(atPath: fileURL.path) else {
      throw TranscriptStoreError.ioFailure("Segments file is missing for \(sessionID)")
    }

    do {
      let handle = try FileHandle(forWritingTo: fileURL)
      try handle.seekToEnd()
      appendHandles[sessionID] = handle
      return handle
    } catch {
      throw TranscriptStoreError.ioFailure(error.localizedDescription)
    }
  }

  private func closeAppendHandle(for sessionID: UUID) throws {
    guard let handle = appendHandles.removeValue(forKey: sessionID) else {
      return
    }
    do {
      try handle.synchronize()
      try handle.close()
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
