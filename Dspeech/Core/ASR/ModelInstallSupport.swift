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

// MARK: - Offline vs. generic-network classification

/// True for the URL-loading error codes that specifically mean "the device has no usable network
/// path" (airplane mode, Wi-Fi/cell dropped mid-transfer, cellular-data disallowed) — as opposed to
/// a server/HTTP-level failure. Each installer maps these to a distinct `.offline` failure kind with
/// its own user-facing copy (C2), so the pilot is told to reconnect rather than shown a generic
/// "network request failed".
func isModelInstallOfflineError(_ error: Error) -> Bool {
  if let urlError = error as? URLError {
    switch urlError.code {
    case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
      return true
    default:
      return false
    }
  }
  let nsError = error as NSError
  if nsError.domain == NSURLErrorDomain {
    return [
      NSURLErrorNotConnectedToInternet,
      NSURLErrorNetworkConnectionLost,
      NSURLErrorDataNotAllowed,
    ].contains(nsError.code)
  }
  return false
}

// MARK: - Resumable single-file staged download (C1)

/// The bytes returned by a caller-supplied ranged fetch: the HTTP status code (so the resume logic
/// can tell an honored `Range` request — 206 Partial Content — from a server that ignored it and
/// re-sent the whole file — 200 OK) and a temporary file the caller owns containing the body bytes.
struct ResumableDownloadResponse: Sendable {
  let statusCode: Int
  let bodyFileURL: URL
}

/// Byte count of a partial-download file, or 0 when it does not exist yet.
func pinnedPartialByteCount(_ url: URL) -> Int64 {
  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
  return (attributes?[.size] as? Int64) ?? 0
}

/// Downloads a single pinned file with HTTP range-resume. Bytes are staged into `<destination>.partial`
/// so an interrupted transfer resumes from the partial's current byte count instead of restarting at
/// zero, then the completed `.partial` is atomically moved to `destination`. The caller provides the
/// actual network fetch as `fetch(fromByteOffset)`: it issues a `Range: bytes=<offset>-` request when
/// the offset is non-zero and returns the response status + body temp file.
///
/// - Complete-file skip is handled by the ENGINE (it never calls this when `destination` already
///   exists), but this guards it too so the helper is safe to call standalone.
/// - A server that ignores the range (returns 200 with the whole body) discards the stale partial and
///   restarts the file cleanly.
/// - The final SHA-256 integrity gate always runs later over the COMPLETE assembled `destination`
///   (in `downloadAndStagePinnedModel`); a corrupt/short partial can therefore never fail-open.
func resumableStagedDownload(
  to destination: URL,
  fetch: (_ fromByteOffset: Int64) async throws -> ResumableDownloadResponse
) async throws {
  let fileManager = FileManager.default
  if fileManager.fileExists(atPath: destination.path) { return }
  try fileManager.createDirectory(
    at: destination.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  let partial = destination.appendingPathExtension("partial")
  let resumeOffset = pinnedPartialByteCount(partial)
  let response = try await fetch(resumeOffset)
  defer { try? ModelInstallFileSystem.removeIfPresent(response.bodyFileURL) }
  guard response.statusCode == 200 || response.statusCode == 206 else {
    throw URLError(.badServerResponse)
  }
  if resumeOffset > 0, response.statusCode == 206 {
    try appendPinnedPartial(from: response.bodyFileURL, to: partial)
  } else {
    // why: a fresh download, or a server that ignored `Range` and re-sent the whole file (200) —
    // either way the temp body IS the complete file, so replace any stale partial with it.
    try ModelInstallFileSystem.removeIfPresent(partial)
    try fileManager.moveItem(at: response.bodyFileURL, to: partial)
  }
  try ModelInstallFileSystem.removeIfPresent(destination)
  try fileManager.moveItem(at: partial, to: destination)
}

/// Appends the bytes of `sourceURL` onto the end of `destinationPartial`, streaming in bounded chunks
/// so resuming a multi-hundred-MB file never loads the whole body into memory.
private func appendPinnedPartial(from sourceURL: URL, to destinationPartial: URL) throws {
  let readHandle = try FileHandle(forReadingFrom: sourceURL)
  defer { try? readHandle.close() }
  let writeHandle = try FileHandle(forWritingTo: destinationPartial)
  defer { try? writeHandle.close() }
  try writeHandle.seekToEnd()
  while true {
    let chunk = try readHandle.read(upToCount: 4 * 1024 * 1024) ?? Data()
    if chunk.isEmpty { break }
    try writeHandle.write(contentsOf: chunk)
  }
}

// MARK: - Pinned download-stage-verify engine

/// Stable per-model staging root. Kept stable (no random UUID) so completed + partial files survive a
/// cancelled/interrupted attempt and are resumed by the next `install()` (C1), never re-downloaded
/// from zero. Cleaned up on successful install and on model deletion.
func pinnedModelStagingRoot(modelsRoot: URL, modelFolderName: String) -> URL {
  modelsRoot.appendingPathComponent(".\(modelFolderName).staging", isDirectory: true)
}

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
  let stagingRoot = pinnedModelStagingRoot(modelsRoot: modelsRoot, modelFolderName: modelFolderName)
  let stagingModelFolder = stagingRoot.appendingPathComponent(modelFolderName, isDirectory: true)
  let finalModelFolder = modelsRoot.appendingPathComponent(modelFolderName, isDirectory: true)
  // why: do NOT wipe the staging folder on entry — completed + partial files from a prior
  // cancelled/interrupted attempt are the resume cache (C1). createDirectory is idempotent.
  try FileManager.default.createDirectory(at: stagingModelFolder, withIntermediateDirectories: true)
  try ModelInstallFileSystem.excludeFromBackup(stagingRoot)

  var completedBytes: Int64 = 0
  var installedFiles: [DownloadedModelFile] = []
  onProgress(completedBytes)

  for spec in specs {
    try Task.checkCancellation()
    let destination = stagingModelFolder.appendingPathComponent(
      spec.relativePath,
      isDirectory: false
    )
    // why: complete-file skip — a file fully staged + verified by a prior attempt is re-verified
    // below (never trusted blind) but not re-downloaded, so a resumed install pays only for the
    // files it still needs. The downloader itself resumes an in-progress `.partial` via a Range
    // request; a checksum failure on any staged file deletes it so the retry re-fetches it fresh.
    if !FileManager.default.fileExists(atPath: destination.path) {
      let source = try sourceURL(spec.relativePath)
      try await download(source, destination)
      guard FileManager.default.fileExists(atPath: destination.path) else {
        throw fileMissing(spec.relativePath)
      }
    }
    let (computedSHA256, actualSizeBytes) = try await ModelInstallFileSystem.fileDigest(
      at: destination
    )
    // why: integrity gate — compare the assembled file against the baked-in pinned hash before
    // accepting it. A mismatch throws (never fail-open) AFTER deleting the corrupt staged file and
    // any leftover `.partial`, so the next attempt re-downloads it fresh rather than resuming or
    // installing tampered/corrupt bytes.
    guard computedSHA256.lowercased() == spec.expectedSHA256.lowercased() else {
      try? ModelInstallFileSystem.removeIfPresent(destination)
      try? ModelInstallFileSystem.removeIfPresent(destination.appendingPathExtension("partial"))
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
  // why: teardown the staging root ONLY on success. On any thrown failure it is preserved as the
  // resume cache; a partial staging folder never installs because the atomic move above happens
  // only after every file verifies. Orphan staging is reclaimed on model deletion.
  try ModelInstallFileSystem.removeIfPresent(stagingRoot)
  try ModelInstallFileSystem.excludeFromBackup(finalModelFolder)
  return StagedPinnedModel(finalModelFolder: finalModelFolder, files: files, sizeBytes: sizeBytes)
}
