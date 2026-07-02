import Foundation
import Testing

@testable import Dspeech

// why: H5 — MXMetricManager cannot be driven in the simulator, so these tests exercise the collector's
// TESTED SEAM: the payload-to-file write, bounded retention prune, newest-first listing, empty state,
// same-second filename collision handling, and non-JSON filtering — all via a temp directory and an
// injected monotonic clock. The MetricKit subscription glue (start/stop + didReceive) is a thin shell.
struct DiagnosticsCollectorTests {
  // why: a monotonic clock so each write gets a distinct second-resolution timestamp (the filename
  // granularity), making retention/ordering deterministic. 60s steps keep timestamps unambiguous.
  private final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private let step: TimeInterval
    init(start: Date, step: TimeInterval) {
      self.current = start
      self.step = step
    }
    func next() -> Date {
      lock.lock()
      defer { lock.unlock() }
      let value = current
      current = current.addingTimeInterval(step)
      return value
    }
  }

  private func makeDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("dspeech-diagnostics-\(UUID().uuidString)", isDirectory: true)
  }

  private func makeCollector(directory: URL, clock: SteppingClock) -> DiagnosticsCollector {
    DiagnosticsCollector(directory: directory, now: { clock.next() })
  }

  @Test func emptyStateHasNoFiles() {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let collector = DiagnosticsCollector(
      directory: dir, now: { Date(timeIntervalSince1970: 0) })

    #expect(collector.fileURLs().isEmpty)
    #expect(!collector.hasAny)
  }

  @Test func storeWritesPayloadFileWithKindInName() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clock = SteppingClock(start: Date(timeIntervalSince1970: 1_000_000), step: 60)
    let collector = makeCollector(directory: dir, clock: clock)

    let payload = Data(#"{"crash":"stack"}"#.utf8)
    let url = try collector.store(kind: .diagnostic, json: payload)

    #expect(url.lastPathComponent.hasSuffix("-diagnostic.json"))
    #expect(try Data(contentsOf: url) == payload)
    #expect(collector.hasAny)
    #expect(collector.fileURLs().count == 1)
    #expect(collector.fileURLs().first == url)
  }

  @Test func metricAndDiagnosticKindsProduceDistinctlyNamedFiles() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clock = SteppingClock(start: Date(timeIntervalSince1970: 2_000_000), step: 60)
    let collector = makeCollector(directory: dir, clock: clock)

    let metricURL = try collector.store(kind: .metric, json: Data("m".utf8))
    let diagnosticURL = try collector.store(kind: .diagnostic, json: Data("d".utf8))

    #expect(metricURL.lastPathComponent.contains("-metric"))
    #expect(diagnosticURL.lastPathComponent.contains("-diagnostic"))
    #expect(collector.fileURLs().count == 2)
  }

  @Test func listingIsNewestFirst() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clock = SteppingClock(start: Date(timeIntervalSince1970: 3_000_000), step: 60)
    let collector = makeCollector(directory: dir, clock: clock)

    let first = try collector.store(kind: .metric, json: Data("1".utf8))
    let second = try collector.store(kind: .metric, json: Data("2".utf8))
    let third = try collector.store(kind: .metric, json: Data("3".utf8))

    // newest-first: the last write (latest timestamp) sorts first.
    #expect(collector.fileURLs() == [third, second, first])
  }

  @Test func retentionPrunesToNewestTwentyOnWrite() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clock = SteppingClock(start: Date(timeIntervalSince1970: 4_000_000), step: 60)
    let collector = makeCollector(directory: dir, clock: clock)

    var written: [URL] = []
    for index in 0..<25 {
      written.append(try collector.store(kind: .metric, json: Data("\(index)".utf8)))
    }

    let remaining = collector.fileURLs()
    #expect(remaining.count == DiagnosticsCollector.maxRetainedFiles)
    // the 20 NEWEST survive; the 5 oldest are pruned.
    let survivors = Set(remaining)
    #expect(written.suffix(20).allSatisfy { survivors.contains($0) })
    #expect(written.prefix(5).allSatisfy { !survivors.contains($0) })
  }

  @Test func sameSecondWritesDoNotOverwriteEachOther() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    // a FIXED clock — both writes resolve to the same timestamp, exercising the collision suffix.
    let collector = DiagnosticsCollector(
      directory: dir, now: { Date(timeIntervalSince1970: 5_000_000) })

    let first = try collector.store(kind: .diagnostic, json: Data("a".utf8))
    let second = try collector.store(kind: .diagnostic, json: Data("b".utf8))

    #expect(first != second)
    #expect(collector.fileURLs().count == 2)
    #expect(try Data(contentsOf: first) == Data("a".utf8))
    #expect(try Data(contentsOf: second) == Data("b".utf8))
  }

  @Test func listingIgnoresNonJSONFiles() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let collector = DiagnosticsCollector(
      directory: dir, now: { Date(timeIntervalSince1970: 6_000_000) })
    _ = try collector.store(kind: .metric, json: Data("m".utf8))
    // a stray non-JSON sibling must never be surfaced to the ShareLink.
    try Data("noise".utf8).write(to: dir.appendingPathComponent("README.txt"))

    let urls = collector.fileURLs()
    #expect(urls.count == 1)
    #expect(urls.allSatisfy { $0.pathExtension == "json" })
  }
}
