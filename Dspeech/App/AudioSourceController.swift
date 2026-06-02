import Foundation
import Observation

@MainActor
@Observable
final class AudioSourceController {
  private let routing: any AudioSessionRouting
  private let settings: AudioSettings

  private(set) var availableInputs: [PortSnapshot] = []
  private(set) var selectedUID: String = ""

  init(routing: any AudioSessionRouting, settings: AudioSettings = AudioSettings()) {
    self.routing = routing
    self.settings = settings
    refresh()
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
