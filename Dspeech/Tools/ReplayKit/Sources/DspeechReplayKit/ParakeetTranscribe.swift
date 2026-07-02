import CryptoKit
import FluidAudio
import Foundation

// why: the host arm for the third ASR engine (Parakeet EOU 120M, FluidAudio StreamingEouAsrManager).
// It drives the SAME production adapter (SystemParakeetStreamingAdapter) the app uses, feeding the
// fixture through it in real-time-shaped blocks and mirroring the live engine's contract: partial
// callbacks are ghost text, an EOU callback finalizes a segment, and reset() MUST follow every EOU
// (FluidAudio latches eouDetected + accumulates tokens across the whole session — without reset
// exactly one EOU fires per session). English-only, matching ParakeetLiveTranscriptionEngine.
enum ParakeetTranscribe {
  // why: 2s of trailing silence forces the EOU debounce (1280ms) to fire for the final utterance,
  // exactly the silence a real mic sees after the pilot stops. Feeding silence is not fabricating
  // text — the model still has to have decoded the words for the EOU transcript to be non-empty.
  private static let trailingSilenceSeconds = 2.0
  private static let feedBlockSeconds = 0.5

  static func run(options: TranscribeArguments) async throws {
    let language = Locale(identifier: options.localeIdentifier).language.languageCode?.identifier
    guard language == "en" else {
      throw ReplayKitError.invalidFixture(
        "Parakeet EOU 120M is English-only (LibriSpeech-trained); locale "
          + "\(options.localeIdentifier) is unsupported. Use an en* locale, or the apple/whisperkit "
          + "engine for non-English audio."
      )
    }

    let audio = try PCM16WAVAudioReader().read(options.audioURL)
    let totalSeconds = Double(audio.samples.count) / audio.sampleRate

    let modelDirectory = try await ParakeetHostModel.resolveModelDirectory(options: options)
    let adapter = SystemParakeetStreamingAdapter(chunkSize: .ms160)
    fputs("parakeet: loading models from \(modelDirectory.path)\n", stderr)
    try await adapter.loadModels(from: modelDirectory)

    let inbox = ParakeetEventInbox()
    await adapter.setPartialCallback { text in inbox.append(.partial(text)) }
    await adapter.setEouCallback { text in inbox.append(.eou(text)) }

    let collector = ParakeetTransmissionCollector(options: options)
    var pendingPartial = ""
    var finalCount = 0

    func drainAndMaybeReset(fedSeconds: Double) async {
      var sawEou = false
      for event in inbox.drain() {
        switch event {
        case .partial(let raw):
          let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
          pendingPartial = trimmed
          if options.emitPartials, !trimmed.isEmpty {
            print("EVENT partial  t=\(format(fedSeconds))  «\(trimmed)»")
          }
        case .eou(let raw):
          let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
          sawEou = true
          pendingPartial = ""
          guard !trimmed.isEmpty else { continue }
          finalCount += 1
          print(
            "EVENT final    t=\(format(fedSeconds))  conf=\(format(unknownConfidence))"
              + "  interim=false  «\(trimmed)»"
          )
          collector.addFinal(text: trimmed, confidence: unknownConfidence, at: fedSeconds)
        }
      }
      // why: mirror ParakeetLiveTranscriptionEngine.handleEndOfUtterance — reset() after every EOU
      // (even an empty one) so the next utterance can latch its own EOU. Without this the whole clip
      // yields a single ever-growing transcript with one EOU.
      if sawEou { await adapter.reset() }
    }

    let blockSamples = max(1, Int((audio.sampleRate * feedBlockSeconds).rounded()))
    var cursor = 0
    while cursor < audio.samples.count {
      let end = min(cursor + blockSamples, audio.samples.count)
      try await adapter.appendSamples(
        Array(audio.samples[cursor..<end]), sampleRate: audio.sampleRate)
      try await adapter.processBufferedAudio()
      await drainAndMaybeReset(fedSeconds: Double(end) / audio.sampleRate)
      cursor = end
    }

    let silence = [Float](
      repeating: 0, count: Int((audio.sampleRate * trailingSilenceSeconds).rounded()))
    try await adapter.appendSamples(silence, sampleRate: audio.sampleRate)
    try await adapter.processBufferedAudio()
    await drainAndMaybeReset(fedSeconds: totalSeconds + trailingSilenceSeconds)

    // why: if the model decoded speech but never crossed the EOU debounce (no closing silence in a
    // clip already at its tail), commit the in-flight partial as an interim final so its words are
    // not lost — the same fail-open the live engine does on a mid-utterance capture failure.
    if finalCount == 0, !pendingPartial.isEmpty {
      finalCount += 1
      print(
        "EVENT final    t=\(format(totalSeconds))  conf=\(format(unknownConfidence))"
          + "  interim=true  «\(pendingPartial)»"
      )
      collector.addFinal(text: pendingPartial, confidence: unknownConfidence, at: totalSeconds)
    }

    await adapter.cleanup()

    print("EVENT done     t=\(format(totalSeconds))")
    collector.finishAndPrint(totalSeconds: totalSeconds)
  }

  // why: the streaming EOU path exposes no confidence (the batch ASRResult.confidence is
  // unreachable). 0 = honest "unknown", matching ParakeetLiveTranscriptionEngine.unknownConfidence,
  // never a fabricated 1.0.
  private static let unknownConfidence = 0.0

  private static func format(_ value: Double) -> String {
    String(format: "%.2f", value)
  }
}

private enum ParakeetStreamEvent: Sendable {
  case partial(String)
  case eou(String)
}

// why: FluidAudio's callbacks are @Sendable and fire on its actor, off this task. Buffer them under
// a lock and drain on the driving task, exactly like TranscribeCallbackInbox for the Apple path.
private final class ParakeetEventInbox: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [ParakeetStreamEvent] = []

  func append(_ event: ParakeetStreamEvent) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }

  func drain() -> [ParakeetStreamEvent] {
    lock.lock()
    let drained = events
    events.removeAll()
    lock.unlock()
    return drained
  }
}

// why: assembles finalized EOU segments into transmissions via the REAL TransmissionAssembler +
// TransmissionClassifier, printing the exact `[DISPLAYED|FILTERED …] «text»` lines run-asr-eval
// parses. Distinct from WhisperKit's collector only in the engine label and that Parakeet drives it
// from EOU finals (no per-word timestamps exist in the streaming path).
private final class ParakeetTransmissionCollector {
  private let options: TranscribeArguments
  private var assembler: TransmissionAssembler
  private var closed: [Transmission] = []

  init(options: TranscribeArguments) {
    self.options = options
    var classifier = TransmissionClassifier(
      configuredCallSign: options.callSign.flatMap { CallSign(raw: $0) },
      localeIdentifier: options.localeIdentifier,
      voicePackActive: false
    )
    assembler = TransmissionAssembler(
      config: TransmissionAssemblerConfig(
        transmissionGapSeconds: options.transmissionGapSeconds
      ),
      localeIdentifier: options.localeIdentifier,
      classify: { text, speakers, endedAt in
        classifier.classify(text: text, speakers: speakers, endedAt: endedAt)
      }
    )
  }

  func addFinal(text: String, confidence: Double, at seconds: Double) {
    let at = Date(timeIntervalSince1970: seconds)
    record(assembler.process(.partial(text: text, at: at)))
    record(
      assembler.process(
        .fragment(
          segment: TranscriptSegment(
            text: text,
            confidence: confidence,
            sourceLanguageCode: "en",
            source: .replay
          ),
          speaker: nil,
          at: at
        )
      )
    )
  }

  func finishAndPrint(totalSeconds: Double) {
    record(assembler.finish(at: Date(timeIntervalSince1970: totalSeconds)))
    let blocks = closed.filter { !$0.text.isEmpty }
    print(
      "TRANSMISSIONS gap=\(String(format: "%.2f", options.transmissionGapSeconds))s "
        + "locale=\(options.localeIdentifier) callsign=\(options.callSign ?? "<none>") engine=parakeet"
    )
    guard !blocks.isEmpty else {
      print("  (no transmissions assembled)")
      return
    }
    for transmission in blocks {
      let kind = transmission.classification.isDisplayed ? "DISPLAYED" : "FILTERED "
      print(
        "[\(kind) \(Self.formatClock(transmission.startedAt))-\(Self.formatClock(transmission.endedAt))] «\(transmission.text)»  (reason: \(Self.describe(transmission.classification)))"
      )
    }
  }

  private func record(_ updates: [TransmissionUpdate]) {
    for update in updates {
      if case .closed(let transmission) = update {
        closed.append(transmission)
      }
    }
  }

  private static func formatClock(_ date: Date) -> String {
    let seconds = date.timeIntervalSince1970
    let minutes = Int(seconds) / 60
    let remainder = seconds - Double(minutes * 60)
    return String(format: "%02d:%05.2f", minutes, remainder)
  }

  private static func describe(_ classification: TransmissionClassification) -> String {
    switch classification {
    case .displayed(let reason): reason.rawValue
    case .filtered(let reason): reason.rawValue
    }
  }
}

// why: host provisioning of the PINNED Parakeet pack. Reuses ParakeetModelInstaller's supply-chain
// manifest (per-file SHA-256) and pinned-revision URL builder verbatim — zero drift from the
// on-device installer — but with a straight-line host downloader (no resumable staging / UI state).
// Every file is verified against the pinned SHA-256 before load; a mismatch throws (never fail-open,
// ADR-0012). A sentinel records a fully-verified pack so the 28 eval invocations don't re-hash 220MB
// each time.
enum ParakeetHostModel {
  static func resolveModelDirectory(options: TranscribeArguments) async throws -> URL {
    if let override = options.modelDir {
      try requireModelBundle(at: override)
      return override
    }
    let leaf = hostModelLeafURL()
    try await ensureVerifiedPack(at: leaf)
    return leaf
  }

  private static let requiredBundleEntries = [
    "streaming_encoder.mlmodelc",
    "decoder.mlmodelc",
    "joint_decision.mlmodelc",
    "vocab.json",
  ]

  private static func hostModelLeafURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".cache/dspeech-parakeet", isDirectory: true)
      .appendingPathComponent(
        ParakeetModelInstaller.repository.components(separatedBy: "/").last
          ?? "parakeet-realtime-eou-120m-coreml",
        isDirectory: true
      )
      .appendingPathComponent(ParakeetModelInstaller.modelFolderName, isDirectory: true)
  }

  private static func requireModelBundle(at directory: URL) throws {
    let missing = requiredBundleEntries.filter {
      !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
    }
    guard missing.isEmpty else {
      throw ReplayKitError.invalidFixture(
        "--model-dir \(directory.path) is not a Parakeet 160ms bundle; missing: "
          + missing.joined(separator: ", ")
      )
    }
  }

  private static func sentinelURL(for leaf: URL) -> URL {
    leaf.appendingPathComponent(".dspeech-verified-\(ParakeetModelInstaller.sourceRevision)")
  }

  private static func ensureVerifiedPack(at leaf: URL) async throws {
    let sentinel = sentinelURL(for: leaf)
    if FileManager.default.fileExists(atPath: sentinel.path),
      allFilesPresentWithExpectedSize(in: leaf)
    {
      return
    }

    try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
    for file in ParakeetModelInstaller.expectedModelFiles {
      let destination = leaf.appendingPathComponent(file.relativePath)
      if fileMatches(destination, expected: file) { continue }
      try await download(file, to: destination)
      let actual = try sha256(of: destination)
      guard actual == file.expectedSHA256 else {
        try? FileManager.default.removeItem(at: destination)
        throw ParakeetModelInstallError.checksumMismatch(
          relativePath: file.relativePath, expected: file.expectedSHA256, actual: actual)
      }
    }
    try Data().write(to: sentinel)
    fputs("parakeet: pinned pack verified (rev \(ParakeetModelInstaller.sourceRevision))\n", stderr)
  }

  private static func allFilesPresentWithExpectedSize(in leaf: URL) -> Bool {
    ParakeetModelInstaller.expectedModelFiles.allSatisfy { file in
      let url = leaf.appendingPathComponent(file.relativePath)
      guard let size = try? fileSize(of: url) else { return false }
      return size == file.sizeBytes
    }
  }

  private static func fileMatches(
    _ url: URL, expected: ParakeetModelInstaller.ExpectedModelFile
  ) -> Bool {
    guard let size = try? fileSize(of: url), size == expected.sizeBytes else { return false }
    guard let actual = try? sha256(of: url) else { return false }
    return actual == expected.expectedSHA256
  }

  private static func download(
    _ file: ParakeetModelInstaller.ExpectedModelFile, to destination: URL
  ) async throws {
    let url = try ParakeetModelInstaller.pinnedDownloadURL(relativePath: file.relativePath)
    fputs("parakeet: downloading \(file.relativePath) (\(file.sizeBytes) bytes)\n", stderr)
    let (temporaryURL, response) = try await URLSession.shared.download(from: url)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw ReplayKitError.invalidFixture(
        "Parakeet model download failed for \(file.relativePath): unexpected response"
      )
    }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: temporaryURL, to: destination)
  }

  private static func fileSize(of url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.int64Value ?? 0
  }

  private static func sha256(of url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    var hasher = SHA256()
    hasher.update(data: data)
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
