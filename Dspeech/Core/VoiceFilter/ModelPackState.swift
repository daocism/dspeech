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

  var percentComplete: Int {
    Int((fractionComplete * 100).rounded())
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
  let localModelPath: String?

  init(
    identifier: String,
    version: String,
    embeddingDimension: Int,
    checksumSHA256: String,
    source: String,
    sizeBytes: Int64,
    installedAt: Date,
    localModelPath: String? = nil
  ) {
    self.identifier = identifier
    self.version = version
    self.embeddingDimension = embeddingDimension
    self.checksumSHA256 = checksumSHA256
    self.source = source
    self.sizeBytes = sizeBytes
    self.installedAt = installedAt
    self.localModelPath = localModelPath
  }
}

struct ModelPackFailure: Equatable, Sendable, Codable {
  enum Kind: String, Equatable, Sendable, Codable {
    case network
    case checksum
    case dimensionMismatch
    case disk
    case cancelled
    case corruptState
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
      return
        "Модель голосового фильтра не установлена. Скачайте пакет, чтобы включить распознавание пилотов."
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
    if let raw = defaults.string(forKey: Self.stateKey) {
      if let launchState = Self.launchArgumentState(raw) {
        return launchState
      }
      return .failed(Self.corruptPersistedStateFailure)
    }
    guard let data = defaults.data(forKey: Self.stateKey) else {
      return .absent
    }
    do {
      let decoded = try JSONDecoder().decode(ModelPackState.self, from: data)
      return decoded.recoveredAfterColdStart()
    } catch {
      return .failed(Self.corruptPersistedStateFailure)
    }
  }

  func saveState(_ state: ModelPackState) {
    guard let data = try? JSONEncoder().encode(state) else { return }
    defaults.set(data, forKey: Self.stateKey)
  }

  private static func launchArgumentState(_ raw: String) -> ModelPackState? {
    switch raw {
    case "absent":
      return .absent
    case "failedRetryable":
      return .failed(
        ModelPackFailure(
          kind: .network,
          userSafeReason:
            "Не удалось скачать пакет модели. Проверьте подключение к сети и попробуйте снова.",
          isRetryable: true
        ))
    case "acquiringHalf":
      return .acquiring(
        ModelPackAcquisition(
          phase: .downloading,
          fractionComplete: 0.42,
          bytesReceived: 6_300_000,
          totalBytes: 15_000_000
        ))
    case "failedPermanent":
      return .failed(
        ModelPackFailure(
          kind: .unknown,
          userSafeReason: "Проверка пакета модели не прошла.",
          isRetryable: false
        ))
    default:
      return nil
    }
  }

  private static let corruptPersistedStateFailure = ModelPackFailure(
    kind: .corruptState,
    userSafeReason:
      "Сохранённое состояние пакета голосовой модели повреждено. Продолжите без голосового фильтра и при необходимости скачайте пакет заново.",
    isRetryable: false
  )
}
