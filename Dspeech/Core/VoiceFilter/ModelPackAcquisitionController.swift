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
    DspeechLog.modelPack.info("model pack acquisition start requested")
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
        DspeechLog.modelPack.info("model pack acquisition cancelled")
        self.finishCancelledAttempt(attemptID)
      } catch {
        DspeechLog.modelPack.error(
          "model pack acquisition failed error=\(error.localizedDescription)"
        )
        self.finish(
          with: .failed(modelPackDownloadFailure(for: error)),
          for: attemptID
        )
      }
    }
  }

  func cancelDownload() {
    DspeechLog.modelPack.info("model pack acquisition cancel requested")
    downloadTask?.cancel()
    downloadTask = nil
    currentAttemptID = nil
    transition(to: .absent)
  }

  func setState(_ state: ModelPackState) {
    DspeechLog.modelPack.info("model pack state override requested")
    downloadTask?.cancel()
    downloadTask = nil
    currentAttemptID = nil
    transition(to: state)
  }

  private func acceptProgress(_ acquisition: ModelPackAcquisition, for attemptID: UUID) {
    guard currentAttemptID == attemptID else { return }
    state = .acquiring(acquisition)
    persist(state)
    DspeechLog.modelPack.debug(
      "model pack acquisition progress phase=\(acquisition.phase.rawValue, privacy: .public) percent=\(acquisition.percentComplete, privacy: .public)"
    )
  }

  private func finish(with finalState: ModelPackState, for attemptID: UUID) {
    guard currentAttemptID == attemptID else { return }
    currentAttemptID = nil
    downloadTask = nil
    transition(to: finalState)
    switch finalState {
    case .installed(let pack):
      DspeechLog.modelPack.info(
        "model pack acquisition succeeded identifier=\(pack.identifier, privacy: .public) version=\(pack.version, privacy: .public) bytes=\(pack.sizeBytes, privacy: .public)"
      )
    case .failed(let failure):
      DspeechLog.modelPack.error(
        "model pack acquisition finished failed kind=\(failure.kind.rawValue, privacy: .public) retryable=\(failure.isRetryable, privacy: .public)"
      )
    case .absent:
      DspeechLog.modelPack.info("model pack acquisition finished state=absent")
    case .acquiring(let acquisition):
      DspeechLog.modelPack.info(
        "model pack acquisition finished state=acquiring phase=\(acquisition.phase.rawValue, privacy: .public)"
      )
    case .disabled:
      DspeechLog.modelPack.info("model pack acquisition finished state=disabled")
    }
  }

  private func finishCancelledAttempt(_ attemptID: UUID) {
    guard currentAttemptID == attemptID else { return }
    currentAttemptID = nil
    downloadTask = nil
    transition(to: .absent)
    DspeechLog.modelPack.info("model pack acquisition finished cancelled state=absent")
  }

  private func transition(to newState: ModelPackState) {
    state = newState
    persist(newState)
    switch newState {
    case .absent:
      DspeechLog.modelPack.info("model pack state changed state=absent")
    case .acquiring(let acquisition):
      DspeechLog.modelPack.info(
        "model pack state changed state=acquiring phase=\(acquisition.phase.rawValue, privacy: .public) percent=\(acquisition.percentComplete, privacy: .public)"
      )
    case .installed(let pack):
      DspeechLog.modelPack.info(
        "model pack state changed state=installed identifier=\(pack.identifier, privacy: .public) version=\(pack.version, privacy: .public)"
      )
    case .failed(let failure):
      DspeechLog.modelPack.error(
        "model pack state changed state=failed kind=\(failure.kind.rawValue, privacy: .public)"
      )
    case .disabled(let pack):
      DspeechLog.modelPack.info(
        "model pack state changed state=disabled identifier=\(pack.identifier, privacy: .public) version=\(pack.version, privacy: .public)"
      )
    }
  }
}

func modelPackDownloadFailure(for error: Error) -> ModelPackFailure {
  if let installError = error as? ModelPackInstallError, installError.isIntegrityFailure {
    DspeechLog.modelPack.error("model pack failure mapped kind=checksum")
    return ModelPackFailure(
      kind: .checksum,
      userSafeReason:
        String(
          localized:
            "The model pack failed its checksum or integrity check. Retry the download to get a verified copy."
        ),
      isRetryable: true
    )
  }

  DspeechLog.modelPack.error("model pack failure mapped kind=network")
  return ModelPackFailure(
    kind: .network,
    userSafeReason:
      String(
        localized: "Couldn't download the model pack. Check your network connection and try again."),
    isRetryable: true
  )
}

func modelPackDeleteFailure(for error: Error) -> ModelPackFailure {
  DspeechLog.modelPack.error("model pack delete failure mapped kind=disk")
  return ModelPackFailure(
    kind: .disk,
    userSafeReason:
      String(
        localized:
          "Couldn't delete the model pack from the device. Check storage access and try again later."
      ),
    isRetryable: false
  )
}
