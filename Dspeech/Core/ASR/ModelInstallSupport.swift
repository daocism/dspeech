import CryptoKit
import Foundation

/// Shared machinery for the pinned per-file model installers (WhisperKit + Parakeet) and the
/// Application-Support-relative path rewriting used by all three model-state storages
/// (WhisperKit / Parakeet / VoiceFilter model-pack).
///
/// The concrete installers stay thin: each owns its pinned manifest, HF repo/revision, URL builder,
/// error taxonomy, and `@Observable` state machine, and delegates the identical download-stage-verify
/// mechanics, filesystem helpers, digest, and disk-full classification here.

// MARK: - Application-Support-relative path rewriting

/// Rewrites an installed model's absolute local path to a path relative to Application Support on
/// persist, and back to an absolute path on load. Keeps persisted state portable across the app
/// container UUID changing between launches (the Application Support prefix is not stable).
enum ApplicationSupportRelativePath {
  static func resolved(_ path: String?, applicationSupportDirectory: URL) -> String? {
    guard let path, !path.isEmpty else { return path }
    if path.hasPrefix("/") {
      let relative = relativeInsideApplicationSupport(
        path,
        applicationSupportDirectory: applicationSupportDirectory
      )
      guard relative != path else { return path }
      return applicationSupportDirectory.appendingPathComponent(relative, isDirectory: true).path
    }
    return applicationSupportDirectory.appendingPathComponent(path, isDirectory: true).path
  }

  static func persisted(_ path: String?, applicationSupportDirectory: URL) -> String? {
    guard let path, !path.isEmpty else { return path }
    return relativeInsideApplicationSupport(
      path,
      applicationSupportDirectory: applicationSupportDirectory
    )
  }

  static func relativeInsideApplicationSupport(
    _ path: String,
    applicationSupportDirectory: URL
  ) -> String {
    guard path.hasPrefix("/") else { return path }
    let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
    let appSupportPath = applicationSupportDirectory.standardizedFileURL.path
    let prefix = appSupportPath.hasSuffix("/") ? appSupportPath : appSupportPath + "/"
    if standardizedPath.hasPrefix(prefix) {
      return String(standardizedPath.dropFirst(prefix.count))
    }
    let marker = "/Application Support/"
    guard let range = standardizedPath.range(of: marker) else {
      return path
    }
    return String(standardizedPath[range.upperBound...])
  }
}

// MARK: - Filesystem + digest helpers

enum ModelInstallFileSystem {
  static func removeIfPresent(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  static func excludeFromBackup(_ url: URL) throws {
    var mutableURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try mutableURL.setResourceValues(values)
  }

  static func availableCapacity(at url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
    guard let freeSize = attributes[.systemFreeSize] as? NSNumber else {
      return 0
    }
    return freeSize.int64Value
  }

  static func hexDigest(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  // why: read + SHA-256 OFF the MainActor and memory-mapped, so verifying the multi-hundred-MB
  // weight files neither blocks the UI nor loads the whole file into the heap (mmap pages are hashed
  // lazily). Returns the actual on-disk size so progress reflects bytes truly received.
  static func fileDigest(at url: URL) async throws -> (sha256: String, sizeBytes: Int64) {
    try await Task.detached(priority: .utility) {
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      return (hexDigest(SHA256.hash(data: data)), Int64(data.count))
    }.value
  }
}

// MARK: - Disk-full classification

/// Walks the NSError domain chain for an out-of-space signal. Each installer prepends its own typed
/// `.insufficientDiskSpace` preflight case before delegating the OS-level domain walk here.
func isModelInstallDiskFullNSError(_ error: Error) -> Bool {
  let nsError = error as NSError
  if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
    return true
  }
  if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(POSIXErrorCode.ENOSPC.rawValue) {
    return true
  }
  if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
    return isModelInstallDiskFullNSError(underlying)
  }
  return false
}

// MARK: - Pinned download-stage-verify engine

struct PinnedModelFileSpec: Equatable, Sendable {
  let relativePath: String
  let sizeBytes: Int64
  let expectedSHA256: String
}

struct DownloadedModelFile: Equatable, Sendable {
  let relativePath: String
  let sha256: String
  let sizeBytes: Int64
}

struct StagedPinnedModel: Sendable {
  let finalModelFolder: URL
  let files: [DownloadedModelFile]
  let sizeBytes: Int64
}

/// Downloads each pinned file into a staging folder, verifies it against its baked-in SHA-256, then
/// atomically moves the completed folder into place. On any failure the staging folder is torn down
/// so a partial or tampered bundle can never install. A checksum mismatch throws (never fail-open).
///
/// The caller (a `@MainActor` installer) provides the per-model config as closures: the pinned URL
/// builder, the file downloader, the concrete error factories, and a progress sink. The engine runs
/// on the MainActor; the heavy digest work hops to a detached utility task via `fileDigest`.
@MainActor
func downloadAndStagePinnedModel(
  modelsRoot: URL,
  modelFolderName: String,
  specs: [PinnedModelFileSpec],
  sourceURL: (String) throws -> URL,
  download: (URL, URL) async throws -> Void,
  fileMissing: (String) -> Error,
  checksumMismatch: (_ relativePath: String, _ expected: String, _ actual: String) -> Error,
  onProgress: (_ completedBytes: Int64) -> Void
) async throws -> StagedPinnedModel {
  let stagingRoot = modelsRoot.appendingPathComponent(
    ".\(modelFolderName).staging-\(UUID().uuidString)",
    isDirectory: true
  )
  let stagingModelFolder = stagingRoot.appendingPathComponent(modelFolderName, isDirectory: true)
  let finalModelFolder = modelsRoot.appendingPathComponent(modelFolderName, isDirectory: true)
  try ModelInstallFileSystem.removeIfPresent(stagingRoot)
  try FileManager.default.createDirectory(at: stagingModelFolder, withIntermediateDirectories: true)
  try ModelInstallFileSystem.excludeFromBackup(stagingRoot)

  do {
    var completedBytes: Int64 = 0
    var installedFiles: [DownloadedModelFile] = []
    onProgress(completedBytes)

    for spec in specs {
      try Task.checkCancellation()
      let destination = stagingModelFolder.appendingPathComponent(
        spec.relativePath,
        isDirectory: false
      )
      let source = try sourceURL(spec.relativePath)
      try await download(source, destination)
      guard FileManager.default.fileExists(atPath: destination.path) else {
        throw fileMissing(spec.relativePath)
      }
      let (computedSHA256, actualSizeBytes) = try await ModelInstallFileSystem.fileDigest(
        at: destination
      )
      // why: integrity gate — compare the just-downloaded bytes against the baked-in pinned hash
      // before accepting the file. A mismatch throws (never fail-open); the staging folder is then
      // torn down by the catch below, so a tampered/corrupt bundle never installs.
      guard computedSHA256.lowercased() == spec.expectedSHA256.lowercased() else {
        throw checksumMismatch(
          spec.relativePath,
          spec.expectedSHA256.lowercased(),
          computedSHA256.lowercased()
        )
      }
      installedFiles.append(
        DownloadedModelFile(
          relativePath: spec.relativePath,
          sha256: computedSHA256,
          sizeBytes: actualSizeBytes
        ))
      // why: advance by the actual received size (== manifest size for any file that passed the
      // checksum gate above), so progress can never diverge or exceed 1.0 on a bad download.
      completedBytes += actualSizeBytes
      onProgress(completedBytes)
    }

    let files = installedFiles.sorted { $0.relativePath < $1.relativePath }
    let sizeBytes = files.reduce(Int64(0)) { $0 + $1.sizeBytes }
    try ModelInstallFileSystem.removeIfPresent(finalModelFolder)
    try FileManager.default.moveItem(at: stagingModelFolder, to: finalModelFolder)
    try ModelInstallFileSystem.removeIfPresent(stagingRoot)
    try ModelInstallFileSystem.excludeFromBackup(finalModelFolder)
    return StagedPinnedModel(finalModelFolder: finalModelFolder, files: files, sizeBytes: sizeBytes)
  } catch {
    // why: best-effort staging teardown, but a removal failure is an OS-level signal — log it
    // (never silently swallow per project error rules) rather than leak orphan staging folders.
    do {
      try ModelInstallFileSystem.removeIfPresent(stagingRoot)
    } catch let teardownError {
      DspeechLog.engine.error(
        "pinned model staging teardown failed error=\(teardownError.localizedDescription, privacy: .public)"
      )
    }
    throw error
  }
}
