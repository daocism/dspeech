import Foundation
import Observation

@MainActor
@Observable
final class AudioSourceController {
  private let routing: any AudioSessionRouting
  private let settings: AudioSettings
  private let meter: any InputLevelMetering
  private let arbiter: AudioCaptureArbiter

  private(set) var availableInputs: [PortSnapshot] = []
  private(set) var selectedUID: String = ""
  private(set) var inputLevel: Double = 0
  private(set) var isMetering = false
  private(set) var selectionError: String?
  private(set) var inputLevelError: String?
  private(set) var routePreparationFailure: AudioRoutePreparationFailure?
  private var meterTask: Task<Void, Never>?
  private var meterLeaseAcquired = false

  init(
    routing: any AudioSessionRouting,
    settings: AudioSettings = AudioSettings(),
    meter: any InputLevelMetering = AVAudioEngineInputLevelMeter(),
    arbiter: AudioCaptureArbiter = .shared
  ) {
    self.routing = routing
    self.settings = settings
    self.meter = meter
    self.arbiter = arbiter
    // why: MEDIUM-2 — if live transcription preempts our capture lease (core capability beats the
    // cosmetic meter), tear our engine down immediately so two AVAudioEngines never tap the shared
    // input. Registered once here for the meter client.
    arbiter.setPreemptionHandler(for: .inputLevelMeter) { [weak self] in
      self?.handlePreemption()
    }
    refresh()
  }

  // why: invoked by the arbiter the instant live transcription preempts our lease. Stop the meter
  // engine + cancel the consume task and clear local state. Do NOT call arbiter.release here — the
  // lease is already reassigned to live transcription, so a release would be a no-op refusal; just
  // clear our local lease flag so a later stopMetering can't double-release.
  private func handlePreemption() {
    meterTask?.cancel()
    meterTask = nil
    meterLeaseAcquired = false
    meter.stop()
    inputLevel = 0
    isMetering = false
    DspeechLog.audioSession.info("input level meter stopped reason=preempted-by-live")
  }

  // why: a transient "test level" meter for the audio-source settings — only run
  // when ASR is not capturing (the caller gates on isListening) so two engines
  // never tap the input at once.
  func startMetering() {
    stopMetering()
    guard arbiter.acquire(.inputLevelMeter) else {
      inputLevel = 0
      inputLevelError = String(
        localized:
          "Audio capture is already in use. Stop transcription before testing the input level.")
      isMetering = false
      return
    }
    meterLeaseAcquired = true
    isMetering = true
    inputLevelError = nil
    meterTask = Task { @MainActor [weak self] in
      guard let self else { return }
      for await event in self.meter.events() {
        switch event {
        case .level(let level):
          self.inputLevel = level
          self.inputLevelError = nil
        case .failed(let message):
          self.inputLevel = 0
          self.inputLevelError = message
          self.isMetering = false
          _ = self.releaseMeterLease()
          self.meter.stop()
          self.meterTask = nil
          return
        }
      }
      self.isMetering = false
      _ = self.releaseMeterLease()
      self.meter.stop()
      self.meterTask = nil
    }
  }

  func stopMetering() {
    meterTask?.cancel()
    meterTask = nil
    _ = releaseMeterLease()
    meter.stop()
    inputLevel = 0
    isMetering = false
  }

  private func releaseMeterLease() -> Bool {
    guard meterLeaseAcquired else { return false }
    meterLeaseAcquired = false
    return arbiter.release(.inputLevelMeter)
  }

  var hasSelectableInputs: Bool { !availableInputs.isEmpty }

  func refresh() {
    routePreparationFailure = routing.routePreparationStatus.failure
    guard routePreparationFailure == nil else {
      availableInputs = []
      selectedUID = ""
      selectionError = nil
      return
    }
    availableInputs = routing.availableInputSnapshots
    if let resolved = PreferredInputResolver.resolve(
      uid: settings.preferredInputUID,
      type: settings.preferredInputType,
      available: availableInputs
    ) {
      selectedUID = resolved.uid
    } else {
      selectedUID =
        routing.currentRouteSnapshot.inputs.first?.uid ?? availableInputs.first?.uid ?? ""
    }
  }

  // why: re-assert the saved input on launch so a wired interface is selected
  // before the user opens settings. A vanished device is simply skipped; an OS
  // rejection is visible because otherwise Settings would claim an inactive source.
  func applyPersistedPreference() {
    guard routePreparationFailure == nil else { return }
    guard
      let port = PreferredInputResolver.resolve(
        uid: settings.preferredInputUID,
        type: settings.preferredInputType,
        available: availableInputs
      )
    else { return }
    do {
      try routing.setPreferredInput(uid: port.uid)
      selectedUID = port.uid
      settings.setPreferred(uid: port.uid, type: port.portType.rawValue)
      selectionError = nil
    } catch {
      selectionError = String(
        localized: "Couldn’t select this input: \(error.localizedDescription)")
      selectedUID = resolvedFallbackUID(rejectedUID: port.uid)
    }
  }

  func select(uid: String) {
    guard routePreparationFailure == nil else { return }
    guard let port = availableInputs.first(where: { $0.uid == uid }) else { return }
    // why: apply the preferred input FIRST and only reflect/persist it if the OS
    // accepted it — otherwise the picker and the saved preference would claim a source
    // the system rejected (vanished/again-in-use), silently lying to the user.
    do {
      try routing.setPreferredInput(uid: uid)
      selectedUID = uid
      settings.setPreferred(uid: uid, type: port.portType.rawValue)
      selectionError = nil
    } catch {
      selectionError = String(
        localized: "Couldn’t select this input: \(error.localizedDescription)")
      selectedUID = routing.currentRouteSnapshot.inputs.first?.uid ?? selectedUID
    }
  }

  private func resolvedFallbackUID(rejectedUID: String) -> String {
    routing.currentRouteSnapshot.inputs.first?.uid
      ?? availableInputs.first(where: { $0.uid != rejectedUID })?.uid
      ?? ""
  }
}
