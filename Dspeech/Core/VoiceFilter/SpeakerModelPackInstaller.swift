import CryptoKit
import FluidAudio
import Foundation

enum ModelPackInstallError: Error, Equatable {
    case filesMissingAfterDownload
    case cancelled
}

struct SpeakerModelPackInstaller: Sendable {
    static let packIdentifier = "fluidaudio-wespeaker-v2"
    static let packVersion = "0.14.7"
    static let embeddingDimension = FluidAudioSpeakerIdentifier.weSpeakerEmbeddingDimension
    static let source = "FluidInference/speaker-diarization-coreml"
    static let segmentationFile = FluidAudioBackendBuilder.segmentationModelFileName
    static let embeddingFile = FluidAudioBackendBuilder.embeddingModelFileName

    func install(
        progress: @escaping @Sendable (ModelPackAcquisition) -> Void
    ) async throws -> InstalledModelPack {
        _ = try await DiarizerModels.downloadIfNeeded(progressHandler: { snapshot in
            progress(Self.acquisition(from: snapshot))
        })

        guard let modelDir = Self.locateModelDirectory() else {
            throw ModelPackInstallError.filesMissingAfterDownload
        }
        let segmentation = modelDir.appendingPathComponent(Self.segmentationFile)
        let embedding = modelDir.appendingPathComponent(Self.embeddingFile)
        let sizeBytes = Self.directorySize(segmentation) + Self.directorySize(embedding)

        return InstalledModelPack(
            identifier: Self.packIdentifier,
            version: Self.packVersion,
            embeddingDimension: Self.embeddingDimension,
            checksumSHA256: Self.fingerprint(of: [segmentation, embedding]),
            source: Self.source,
            sizeBytes: sizeBytes,
            installedAt: Date(),
            localModelPath: modelDir.path
        )
    }

    static func locateModelDirectory(
        in root: URL = fluidAudioRoot(),
        fileManager: FileManager = .default
    ) -> URL? {
        let direct = DiarizerModels.defaultModelsDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("speaker-diarization-coreml", isDirectory: true)
        if hasBothModels(at: direct, fileManager: fileManager) { return direct }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }
            if hasBothModels(at: url, fileManager: fileManager) { return url }
        }
        return nil
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

    private static func directorySize(_ url: URL, fileManager: FileManager = .default) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private static func fingerprint(of directories: [URL], fileManager: FileManager = .default) -> String {
        var manifest = ""
        for directory in directories.sorted(by: { $0.path < $1.path }) {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            ) else { continue }
            var entries: [String] = []
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true {
                    entries.append("\(fileURL.lastPathComponent):\(values?.fileSize ?? 0)")
                }
            }
            manifest += directory.lastPathComponent + "[" + entries.sorted().joined(separator: ",") + "]"
        }
        let digest = SHA256.hash(data: Data(manifest.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
