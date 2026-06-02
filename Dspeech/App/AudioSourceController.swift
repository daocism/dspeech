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
    meterTask = Task { @MainActor [weak self] in
      guard let self else { return }
      for await level in self.meter.levels() {
        self.inputLevel = level
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
  // before the user opens settings. A vanished device is simply skipped.
  func applyPersistedPreference() {
    guard let uid = settings.preferredInputUID,
      availableInputs.contains(where: { $0.uid == uid })
    else { return }
    try? routing.setPreferredInput(uid: uid)
  }

  func select(uid: String) {
    guard let port = availableInputs.first(where: { $0.uid == uid }) else { return }
    selectedUID = uid
    settings.setPreferred(uid: uid, type: port.portType.rawValue)
    // why: the OS can reject a preferred input that vanished between enumeration
    // and selection; route-health monitoring reflects the actual active input, so
    // a rejected preference surfaces there rather than throwing to a dead end.
    try? routing.setPreferredInput(uid: uid)
  }
}
