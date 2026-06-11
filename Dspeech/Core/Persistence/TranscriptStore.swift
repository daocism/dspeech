import Foundation

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
