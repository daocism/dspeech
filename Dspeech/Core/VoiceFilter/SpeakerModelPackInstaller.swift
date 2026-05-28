import CryptoKit
import FluidAudio
import Foundation

enum ModelPackInstallError: Error, Equatable {
    case filesMissingAfterDownload
    case cancelled
    case integrityExpectedFileMissing(String)
    case integrityUnexpectedFile(String)
    case integrityChecksumMismatch(relativePath: String, expectedSHA256: String, actualSHA256: String)
    case integrityFileUnreadable(String)
    case integrityManifestEmpty

    var isIntegrityFailure: Bool {
        switch self {
        case .integrityExpectedFileMissing,
             .integrityUnexpectedFile,
             .integrityChecksumMismatch,
             .integrityFileUnreadable,
             .integrityManifestEmpty:
            return true
        case .filesMissingAfterDownload, .cancelled:
            return false
        }
    }
}

struct SpeakerModelPackInstaller: Sendable {
    struct ExpectedModelFile: Equatable, Sendable {
        let relativePath: String
        let sha256: String
    }

    struct VerifiedModelPack: Equatable, Sendable {
        let checksumSHA256: String
        let sizeBytes: Int64
    }

    static let packIdentifier = "fluidaudio-wespeaker-v2"
    static let packVersion = "0.14.7"
    static let embeddingDimension = FluidAudioSpeakerIdentifier.weSpeakerEmbeddingDimension
    static let source = "FluidInference/speaker-diarization-coreml"
    static let segmentationFile = FluidAudioBackendBuilder.segmentationModelFileName
    static let embeddingFile = FluidAudioBackendBuilder.embeddingModelFileName
    static let expectedModelFileManifest: [ExpectedModelFile] = [
        ExpectedModelFile(
            relativePath: "pyannote_segmentation.mlmodelc/analytics/coremldata.bin",
            sha256: "b379db0541b35344a34bb7540783ae704c11599bbed5aa8bbbda11c20ad215ee"
        ),
        ExpectedModelFile(
            relativePath: "pyannote_segmentation.mlmodelc/coremldata.bin",
            sha256: "4a450ea1b053b9eb7eef0cab6971018076600840c7e246d064e7c5387f456c98"
        ),
        ExpectedModelFile(
            relativePath: "pyannote_segmentation.mlmodelc/metadata.json",
            sha256: "44e1fa36d6abafacf688beccad99f7569394248d8bb41545829997c67668c08c"
        ),
        ExpectedModelFile(
            relativePath: "pyannote_segmentation.mlmodelc/model.mil",
            sha256: "97f2dec6f83e80bf4247b98e13c2dde19f92c05820ef08068bbf554488d70bdd"
        ),
        ExpectedModelFile(
            relativePath: "pyannote_segmentation.mlmodelc/weights/weight.bin",
            sha256: "0266f4ad4d843ecf31ef9220ad6b80616b3ec64a4404b64f3ea0371554e236ec"
        ),
        ExpectedModelFile(
            relativePath: "wespeaker_v2.mlmodelc/analytics/coremldata.bin",
            sha256: "d2b1fcde6121aea3ff0e14c1dc50d09dacb0314a2e89156353c31804230a422f"
        ),
        ExpectedModelFile(
            relativePath: "wespeaker_v2.mlmodelc/coremldata.bin",
            sha256: "6feb2472a71fa9d8a84020c85206138a4f6261c565c9884bf518d59dd5838da7"
        ),
        ExpectedModelFile(
            relativePath: "wespeaker_v2.mlmodelc/metadata.json",
            sha256: "ddc4858b4051254098015cd0b97080149839d697faf7b036f933190e70b26758"
        ),
        ExpectedModelFile(
            relativePath: "wespeaker_v2.mlmodelc/model.mil",
            sha256: "2850f775d6ba659f01f616fed77ce6a45a25de3eb7e4bf3a4b07b658be4e13dd"
        ),
        ExpectedModelFile(
            relativePath: "wespeaker_v2.mlmodelc/weights/weight.bin",
            sha256: "34004f6798d35cad7071e2fdc67e63faaa782f53697e1cb49bcb452cf81ae151"
        )
    ]

    func install(
        progress: @escaping @Sendable (ModelPackAcquisition) -> Void
    ) async throws -> InstalledModelPack {
        let cacheRoot = Self.modelCacheRoot()
        try await Self.downloadModelPack(to: cacheRoot, progress: progress)
        do {
            return try Self.installedPackAfterVerification()
        } catch let error as ModelPackInstallError {
            guard error.isIntegrityFailure else { throw error }
            if let modelDir = Self.locateModelDirectory() {
                try Self.removeModelDirectory(modelDir)
            }
            try await Self.downloadModelPack(to: cacheRoot, progress: progress)
            return try Self.installedPackAfterVerification()
        }
    }

    static func installedPackAfterVerification() throws -> InstalledModelPack {
        guard let modelDir = Self.locateModelDirectory() else {
            throw ModelPackInstallError.filesMissingAfterDownload
        }
        let verified = try Self.verifyModelPack(at: modelDir)

        return InstalledModelPack(
            identifier: Self.packIdentifier,
            version: Self.packVersion,
            embeddingDimension: Self.embeddingDimension,
            checksumSHA256: verified.checksumSHA256,
            source: Self.source,
            sizeBytes: verified.sizeBytes,
            installedAt: Date(),
            localModelPath: modelDir.path
        )
    }

    static func locateModelDirectory(
        in root: URL = fluidAudioRoot(),
        fileManager: FileManager = .default
    ) -> URL? {
        let cacheRoot = modelCacheRoot()
        let directCandidates = [
            cacheRoot.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true),
            cacheRoot.appendingPathComponent("speaker-diarization-coreml", isDirectory: true)
        ]
        for direct in directCandidates where hasBothModels(at: direct, fileManager: fileManager) {
            return direct
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            let isDirectory: Bool
            do {
                isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
            } catch {
                continue
            }
            guard isDirectory else { continue }
            if hasBothModels(at: url, fileManager: fileManager) { return url }
        }
        return nil
    }

    static func modelCacheRoot() -> URL {
        DiarizerModels.defaultModelsDirectory().deletingLastPathComponent()
    }

    static func verifyModelPack(
        at modelDirectory: URL,
        manifest: [ExpectedModelFile] = expectedModelFileManifest,
        fileManager: FileManager = .default
    ) throws -> VerifiedModelPack {
        guard !manifest.isEmpty else {
            throw ModelPackInstallError.integrityManifestEmpty
        }
        let normalizedManifest = manifest.sorted { $0.relativePath < $1.relativePath }
        let expectedPaths = Set(normalizedManifest.map(\.relativePath))
        let actualPaths = try regularModelFiles(at: modelDirectory, fileManager: fileManager)

        for relativePath in expectedPaths.subtracting(actualPaths).sorted() {
            throw ModelPackInstallError.integrityExpectedFileMissing(relativePath)
        }
        for relativePath in actualPaths.subtracting(expectedPaths).sorted() {
            throw ModelPackInstallError.integrityUnexpectedFile(relativePath)
        }

        var packHasher = SHA256()
        var sizeBytes: Int64 = 0
        for entry in normalizedManifest {
            let fileURL = modelDirectory.appendingPathComponent(entry.relativePath, isDirectory: false)
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw ModelPackInstallError.integrityFileUnreadable(entry.relativePath)
            }

            let digest = SHA256.hash(data: data)
            let actualSHA256 = hexDigest(digest)
            guard actualSHA256 == entry.sha256 else {
                throw ModelPackInstallError.integrityChecksumMismatch(
                    relativePath: entry.relativePath,
                    expectedSHA256: entry.sha256,
                    actualSHA256: actualSHA256
                )
            }

            packHasher.update(data: digestData(digest))
            sizeBytes += Int64(data.count)
        }

        return VerifiedModelPack(
            checksumSHA256: hexDigest(packHasher.finalize()),
            sizeBytes: sizeBytes
        )
    }

    static func fluidAudioRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("FluidAudio", isDirectory: true)
    }

    private static func hasBothModels(at directory: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent(segmentationFile).path)
            && fileManager.fileExists(atPath: directory.appendingPathComponent(embeddingFile).path)
    }

    private static func acquisition(from snapshot: DownloadUtils.DownloadProgress) -> ModelPackAcquisition {
        switch snapshot.phase {
        case .compiling:
            return ModelPackAcquisition(phase: .importing, fractionComplete: snapshot.fractionCompleted)
        case .listing, .downloading:
            return ModelPackAcquisition(phase: .downloading, fractionComplete: snapshot.fractionCompleted)
        }
    }

    private static func downloadModelPack(
        to cacheRoot: URL,
        progress: @escaping @Sendable (ModelPackAcquisition) -> Void
    ) async throws {
        try await DownloadUtils.downloadRepo(.diarizer, to: cacheRoot, progressHandler: { snapshot in
            progress(Self.acquisition(from: snapshot))
        })
    }

    private static func removeModelDirectory(_ modelDir: URL, fileManager: FileManager = .default) throws {
        try fileManager.removeItem(at: modelDir)
    }

    private static func regularModelFiles(at modelDirectory: URL, fileManager: FileManager) throws -> Set<String> {
        var files = Set<String>()
        for directoryName in [segmentationFile, embeddingFile] {
            let directory = modelDirectory.appendingPathComponent(directoryName, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ModelPackInstallError.integrityExpectedFileMissing(directoryName)
            }
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) else {
                throw ModelPackInstallError.integrityExpectedFileMissing(directoryName)
            }
            for case let fileURL as URL in enumerator {
                let relativePath = relativePath(from: modelDirectory, to: fileURL)
                do {
                    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                    if values.isRegularFile == true {
                        files.insert(relativePath)
                    }
                } catch {
                    throw ModelPackInstallError.integrityFileUnreadable(relativePath)
                }
            }
        }
        return files
    }

    private static func relativePath(from root: URL, to fileURL: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return fileURL.lastPathComponent }
        return String(filePath.dropFirst(prefix.count))
    }

    private static func digestData(_ digest: SHA256.Digest) -> Data {
        digest.withUnsafeBytes { Data($0) }
    }

    private static func hexDigest(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
