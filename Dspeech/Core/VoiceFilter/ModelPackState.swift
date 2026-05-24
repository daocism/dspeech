import Foundation

struct ModelPackAcquisition: Equatable, Sendable, Codable {
    enum Phase: String, Equatable, Sendable, Codable {
        case downloading
        case importing
    }

    let phase: Phase
    let fractionComplete: Double
    let bytesReceived: Int64?
    let totalBytes: Int64?

    init(
        phase: Phase,
        fractionComplete: Double,
        bytesReceived: Int64? = nil,
        totalBytes: Int64? = nil
    ) {
        self.phase = phase
        self.fractionComplete = min(max(fractionComplete, 0), 1)
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
    }
}

struct InstalledModelPack: Equatable, Sendable, Codable {
    let identifier: String
    let version: String
    let embeddingDimension: Int
    let checksumSHA256: String
    let source: String
    let sizeBytes: Int64
    let installedAt: Date
}

struct ModelPackFailure: Equatable, Sendable, Codable {
    enum Kind: String, Equatable, Sendable, Codable {
        case network
        case checksum
        case dimensionMismatch
        case disk
        case cancelled
        case unknown
    }

    let kind: Kind
    let userSafeReason: String
    let isRetryable: Bool
}

enum ModelPackState: Equatable, Sendable, Codable {
    case absent
    case acquiring(ModelPackAcquisition)
    case installed(InstalledModelPack)
    case failed(ModelPackFailure)
    case disabled(InstalledModelPack)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    var installedPack: InstalledModelPack? {
        switch self {
        case .installed(let pack), .disabled(let pack):
            return pack
        case .absent, .acquiring, .failed:
            return nil
        }
    }

    var allowsEnrollment: Bool {
        isInstalled
    }

    var capabilityReason: String {
        switch self {
        case .absent:
            return "Модель голосового фильтра не установлена. Скачайте пакет, чтобы включить распознавание пилотов."
        case .acquiring(let acquisition):
            switch acquisition.phase {
            case .downloading:
                return "Идёт загрузка модели голосового фильтра…"
            case .importing:
                return "Идёт установка модели голосового фильтра…"
            }
        case .installed:
            return "Модель установлена, но локальный распознаватель недоступен в этой сборке."
        case .failed(let failure):
            return failure.userSafeReason
        case .disabled:
            return "Голосовой фильтр выключен. Модель установлена и готова к работе."
        }
    }

    func recoveredAfterColdStart() -> ModelPackState {
        if case .acquiring = self {
            return .absent
        }
        return self
    }
}

protocol ModelPackStateStorage: Sendable {
    func loadState() -> ModelPackState
    func saveState(_ state: ModelPackState)
}

struct UserDefaultsModelPackStateStorage: ModelPackStateStorage, @unchecked Sendable {
    static let stateKey = "dspeech.voicefilter.modelpack.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadState() -> ModelPackState {
        guard let data = defaults.data(forKey: Self.stateKey),
              let decoded = try? JSONDecoder().decode(ModelPackState.self, from: data) else {
            return .absent
        }
        return decoded.recoveredAfterColdStart()
    }

    func saveState(_ state: ModelPackState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.stateKey)
    }
}
