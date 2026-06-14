import Foundation
import Observation

protocol ModelPackInstalling: Sendable {
  func install(
    progress: @escaping @Sendable (ModelPackAcquisition) -> Void
  ) async throws -> InstalledModelPack
}

extension SpeakerModelPackInstaller: ModelPackInstalling {}

// why: an acquisition attempt can only END as installed or failed — never absent/acquiring/disabled.
// Narrowing finish()'s input to these two makes the illegal terminal states unrepresentable instead
// of dead switch arms, so the compiler enforces the contract.
enum ModelPackAcquisitionFinality: Equatable, Sendable {
  case installed(InstalledModelPack)
  case failed(ModelPackFailure)

  var state: ModelPackState {
    switch self {
    case .installed(let pack): return .installed(pack)
    case .failed(let failure): return .failed(failure)
    }
  }
}

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

  private func finish(with finality: ModelPackAcquisitionFinality, for attemptID: UUID) {
    guard currentAttemptID == attemptID else { return }
    currentAttemptID = nil
    downloadTask = nil
    transition(to: finality.state)
    switch finality {
    case .installed(let pack):
      DspeechLog.modelPack.info(
        "model pack acquisition succeeded identifier=\(pack.identifier, privacy: .public) version=\(pack.version, privacy: .public) bytes=\(pack.sizeBytes, privacy: .public)"
      )
    case .failed(let failure):
      DspeechLog.modelPack.error(
        "model pack acquisition finished failed kind=\(failure.kind.rawValue, privacy: .public) retryable=\(failure.isRetryable, privacy: .public)"
      )
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
            "The model pack changed upstream and no longer matches Dspeech's pinned integrity manifest. Continue without the voice filter until the app updates its model manifest."
        ),
      isRetryable: false
    )
  }

  if isDiskFull(error) {
    DspeechLog.modelPack.error("model pack failure mapped kind=disk")
    return ModelPackFailure(
      kind: .disk,
      userSafeReason:
        String(
          localized:
            "There isn't enough device storage to install the voice filter model pack. Free storage and try again."
        ),
      isRetryable: true
    )
  }

  if error is CancellationError || error as? ModelPackInstallError == .cancelled {
    DspeechLog.modelPack.info("model pack failure mapped kind=cancelled")
    return ModelPackFailure(
      kind: .cancelled,
      userSafeReason: String(localized: "The model pack download was cancelled."),
      isRetryable: true
    )
  }

  if error is URLError {
    DspeechLog.modelPack.error("model pack failure mapped kind=network")
    return ModelPackFailure(
      kind: .network,
      userSafeReason:
        String(
          localized:
            "Couldn't download the model pack because the network request failed. Check your connection and try again."
        ),
      isRetryable: true
    )
  }

  let nsError = error as NSError
  if nsError.domain == NSURLErrorDomain {
    DspeechLog.modelPack.error("model pack failure mapped kind=network")
    return ModelPackFailure(
      kind: .network,
      userSafeReason:
        String(
          localized:
            "Couldn't download the model pack because the network request failed. Check your connection and try again."
        ),
      isRetryable: true
    )
  }

  DspeechLog.modelPack.error("model pack failure mapped kind=unknown")
  return ModelPackFailure(
    kind: .unknown,
    userSafeReason:
      String(
        localized:
          "Couldn't install the model pack because the installer did not produce the expected local files."
      ),
    isRetryable: false
  )
}

func modelPackDeleteFailure(for error: Error) -> ModelPackFailure {
  let nsError = error as NSError
  DspeechLog.modelPack.error(
    "model pack delete failure mapped kind=disk domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
  )
  return ModelPackFailure(
    kind: .disk,
    userSafeReason:
      String(
        localized:
          "Couldn't delete the model pack from the device. The device reported a storage or file-access error. Try again later."
      ),
    isRetryable: false
  )
}

private func isDiskFull(_ error: Error) -> Bool {
  if case .insufficientDiskSpace = error as? ModelPackInstallError {
    return true
  }
  let nsError = error as NSError
  if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
    return true
  }
  if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(POSIXErrorCode.ENOSPC.rawValue) {
    return true
  }
  if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
    return isDiskFull(underlying)
  }
  return false
}
