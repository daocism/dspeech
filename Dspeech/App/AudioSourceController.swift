import Foundation
import Observation

@MainActor
@Observable
final class AudioSourceController {
  private let routing: any AudioSessionRouting
  private let settings: AudioSettings
  private let meter: any InputLevelMetering

  private(set) var availableInputs: [PortSnapshot] = []
  private(set) var selectedUID: String = ""
  private(set) var inputLevel: Double = 0
  private(set) var isMetering = false
  private(set) var selectionError: String?
  private(set) var inputLevelError: String?
  private(set) var routePreparationFailure: AudioRoutePreparationFailure?
  private var meterTask: Task<Void, Never>?

  init(
    routing: any AudioSessionRouting,
    settings: AudioSettings = AudioSettings(),
    meter: any InputLevelMetering = AVAudioEngineInputLevelMeter()
  ) {
    self.routing = routing
    self.settings = settings
    self.meter = meter
    refresh()
  }

  // why: a transient "test level" meter for the audio-source settings — only run
  // when ASR is not capturing (the caller gates on isListening) so two engines
  // never tap the input at once.
  func startMetering() {
    stopMetering()
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
          self.meter.stop()
          self.meterTask = nil
          return
        }
      }
    }
  }

  func stopMetering() {
    meterTask?.cancel()
    meterTask = nil
    meter.stop()
    inputLevel = 0
    isMetering = false
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
    guard let uid = settings.preferredInputUID,
      let port = availableInputs.first(where: { $0.uid == uid })
    else { return }
    do {
      try routing.setPreferredInput(uid: uid)
      selectedUID = uid
      settings.setPreferred(uid: uid, type: port.portType.rawValue)
      selectionError = nil
    } catch {
      selectionError = "Не удалось выбрать этот вход: \(error.localizedDescription)"
      selectedUID = resolvedFallbackUID(rejectedUID: uid)
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
      selectionError = "Не удалось выбрать этот вход: \(error.localizedDescription)"
      selectedUID = routing.currentRouteSnapshot.inputs.first?.uid ?? selectedUID
    }
  }

  private func resolvedFallbackUID(rejectedUID: String) -> String {
    routing.currentRouteSnapshot.inputs.first?.uid
      ?? availableInputs.first(where: { $0.uid != rejectedUID })?.uid
      ?? ""
  }
}
