import Foundation
import MetricKit

/// On-device crash / hang / performance diagnostics collector (H5).
///
/// Subscribes to MetricKit and writes each received payload's JSON representation to
/// `Application Support/Dspeech/Diagnostics/<timestamp>-<kind>.json`, keeping only the newest
/// `maxRetainedFiles` files (older ones are pruned on each write). Local-only (ADR 0002): nothing
/// leaves the device — the JSON files are surfaced solely through the user's explicit ShareLink in
/// Settings, which is the ONLY export path.
///
/// The MetricKit subscription (`start()`/`stop()` + the `didReceive` glue) is a thin imperative
/// shell: MXMetricManager cannot be driven in the simulator, so the tested seam is `store(kind:json:)`
/// — the payload-to-file write + retention prune + listing accessors, which take injected content, a
/// temp directory, and a `now` clock.
final class DiagnosticsCollector: NSObject, @unchecked Sendable {
  enum PayloadKind: String, Sendable, CaseIterable {
    case diagnostic
    case metric
  }

  enum DiagnosticsError: Error, Equatable {
    case writeFailed(String)
  }

  /// Bounded retention — the newest N files are kept; older ones are pruned on every write so the
  /// on-device diagnostics footprint stays small and never grows unbounded.
  static let maxRetainedFiles = 20

  private let directory: URL
  private let fileManager: FileManager
  private let now: @Sendable () -> Date
  // why: MetricKit delivers payloads on a background queue and Settings reads on the MainActor, so
  // the file operations are serialized under a lock — the class is a shared reference across actors.
  private let lock = NSLock()
  private var isSubscribed = false

  init(
    directory: URL? = nil,
    fileManager: FileManager = .default,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.fileManager = fileManager
    self.directory =
      directory
      ?? ApplicationSupport.directoryOrTrap(fileManager: fileManager)
      .appendingPathComponent("Dspeech", isDirectory: true)
      .appendingPathComponent("Diagnostics", isDirectory: true)
    self.now = now
    super.init()
  }

  // MARK: - MetricKit subscription shell (untestable in-simulator; kept minimal)

  /// Registers with MetricKit. Idempotent — a second call is a no-op so a re-entrant lifecycle hook
  /// cannot double-subscribe.
  func start() {
    lock.lock()
    let alreadySubscribed = isSubscribed
    isSubscribed = true
    lock.unlock()
    guard !alreadySubscribed else { return }
    MXMetricManager.shared.add(self)
  }

  func stop() {
    lock.lock()
    let wasSubscribed = isSubscribed
    isSubscribed = false
    lock.unlock()
    guard wasSubscribed else { return }
    MXMetricManager.shared.remove(self)
  }

  // MARK: - Tested core: write + prune + listing

  /// Writes one payload's JSON to `<timestamp>-<kind>.json`, then prunes to the newest
  /// `maxRetainedFiles`. Returns the written file URL. Throws (never fail-open into a silent drop) so
  /// the caller can log; the MetricKit callback boundary catches and logs, keeping a write failure
  /// from ever crashing the app on a real device.
  @discardableResult
  func store(kind: PayloadKind, json: Data) throws -> URL {
    lock.lock()
    defer { lock.unlock() }
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = uniqueFileURL(kind: kind)
      try json.write(to: url, options: .atomic)
      pruneLocked()
      return url
    } catch {
      throw DiagnosticsError.writeFailed(error.localizedDescription)
    }
  }

  /// Every collected diagnostics file, newest first (lexicographically-descending fixed-width UTC
  /// timestamp == reverse chronological). This is exactly what the Settings ShareLink shares.
  func fileURLs() -> [URL] {
    lock.lock()
    defer { lock.unlock() }
    return collectedFilesLocked()
  }

  /// True when at least one diagnostics file exists — gates the Settings ShareLink vs. the empty copy.
  var hasAny: Bool {
    !fileURLs().isEmpty
  }

  // MARK: - Locked helpers (caller holds `lock`, or a public accessor that does)

  private func uniqueFileURL(kind: PayloadKind) -> URL {
    let stamp = Self.timestamp(now())
    var candidate = directory.appendingPathComponent("\(stamp)-\(kind.rawValue).json")
    var suffix = 2
    // why: two payloads delivered in the same second would collide on the timestamp filename; a
    // numeric suffix keeps each one instead of overwriting an earlier crash report.
    while fileManager.fileExists(atPath: candidate.path) {
      candidate = directory.appendingPathComponent("\(stamp)-\(kind.rawValue)-\(suffix).json")
      suffix += 1
    }
    return candidate
  }

  private func collectedFilesLocked() -> [URL] {
    guard
      let contents = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }
    return
      contents
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
  }

  private func pruneLocked() {
    let files = collectedFilesLocked()
    guard files.count > Self.maxRetainedFiles else { return }
    for stale in files[Self.maxRetainedFiles...] {
      try? fileManager.removeItem(at: stale)
    }
  }

  // why: a fixed-width UTC timestamp with dashes for the time separators — filesystem-safe (no ":")
  // and lexicographically sortable == chronologically sortable, which the newest-first listing relies
  // on. POSIX locale + gregorian calendar so it never drifts with the device locale/calendar.
  private static func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
    return formatter.string(from: date)
  }
}

// MARK: - MetricKit delivery (thin shell)

extension DiagnosticsCollector: MXMetricManagerSubscriber {
  func didReceive(_ payloads: [MXMetricPayload]) {
    for payload in payloads {
      persist(kind: .metric, json: payload.jsonRepresentation())
    }
  }

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    for payload in payloads {
      persist(kind: .diagnostic, json: payload.jsonRepresentation())
    }
  }

  // why: the MetricKit callback is the subsystem boundary — a failed write must be logged for a
  // sysdiagnose trail, never crash the app or vanish silently (fail-fast policy, boundary-catch).
  private func persist(kind: PayloadKind, json: Data) {
    do {
      _ = try store(kind: kind, json: json)
    } catch {
      DspeechLog.persistence.error(
        "diagnostics payload write failed kind=\(kind.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
