import Foundation
import Observation

protocol ModelPackInstalling: Sendable {
  func install(
    progress: @escaping @Sendable (ModelPackAcquisition) -> Void
  ) async throws -> InstalledModelPack
}

extension SpeakerModelPackInstaller: ModelPackInstalling {}

@MainActor
@Observable
final class ModelPackAcquisitionController {
  private(set) var state: ModelPackState

  private let installer: any ModelPackInstalling
  private let persist: @MainActor (ModelPackState) -> Void
  private var downloadTask: Task<Void, Never>?
  private var currentAttemptID: UUID?

  init(
    initialState: ModelPackState,
    installer: any ModelPackInstalling = SpeakerModelPackInstaller(),
    persist: @escaping @MainActor (ModelPackState) -> Void = { _ in }
  ) {
    self.state = initialState
    self.installer = installer
    self.persist = persist
  }

  func startDownload() {
    downloadTask?.cancel()

    let attemptID = UUID()
    currentAttemptID = attemptID
    transition(to: .acquiring(ModelPackAcquisition(phase: .downloading, fractionComplete: 0)))

    downloadTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let pack = try await self.installer.install { [weak self] acquisition in
          Task { @MainActor [weak self] in
            self?.acceptProgress(acquisition, for: attemptID)
          }
        }
        self.finish(with: .installed(pack), for: attemptID)
      } catch is CancellationError {
        self.finishCancelledAttempt(attemptID)
      } catch {
        self.finish(
          with: .failed(modelPackDownloadFailure(for: error)),
          for: attemptID
        )
      }
    }
  }

  func cancelDownload() {
    downloadTask?.cancel()
    downloadTask = nil
    currentAttemptID = nil
    transition(to: .absent)
  }

  func setState(_ state: ModelPackState) {
    downloadTask?.cancel()
    downloadTask = nil
    currentAttemptID = nil
    transition(to: state)
  }

  private func acceptProgress(_ acquisition: ModelPackAcquisition, for attemptID: UUID) {
    guard currentAttemptID == attemptID else { return }
    state = .acquiring(acquisition)
    persist(state)
  }

  private func finish(with finalState: ModelPackState, for attemptID: UUID) {
    guard currentAttemptID == attemptID else { return }
    currentAttemptID = nil
    downloadTask = nil
    transition(to: finalState)
  }

  private func finishCancelledAttempt(_ attemptID: UUID) {
    guard currentAttemptID == attemptID else { return }
    currentAttemptID = nil
    downloadTask = nil
    transition(to: .absent)
  }

  private func transition(to newState: ModelPackState) {
    state = newState
    persist(newState)
  }
}

func modelPackDownloadFailure(for error: Error) -> ModelPackFailure {
  if let installError = error as? ModelPackInstallError, installError.isIntegrityFailure {
    return ModelPackFailure(
      kind: .checksum,
      userSafeReason:
        "Пакет модели не прошёл проверку контрольной суммы или целостности. Повторите загрузку, чтобы скачать проверенную копию.",
      isRetryable: true
    )
  }

  return ModelPackFailure(
    kind: .network,
    userSafeReason:
      "Не удалось скачать пакет модели. Проверьте подключение к сети и попробуйте снова.",
    isRetryable: true
  )
}

func modelPackDeleteFailure(for error: Error) -> ModelPackFailure {
  ModelPackFailure(
    kind: .disk,
    userSafeReason:
      "Не удалось удалить пакет модели с устройства. Проверьте доступ к хранилищу и попробуйте позже.",
    isRetryable: false
  )
}
