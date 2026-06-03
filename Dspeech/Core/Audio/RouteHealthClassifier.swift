import Foundation

enum RouteHealthClassifier {
  static func classify(
    route: RouteSnapshot,
    availableInputs: [PortSnapshot]
  ) -> RouteHealthAssessment {
    if let primary = route.inputs.first {
      return assess(port: primary)
    }

    // why: pre-activation the active route reports no input even though a usable
    // mic exists in availableInputs; classifying from it keeps Start enabled
    // instead of falsely reporting .noInput before the engine activates capture.
    if let capturable = availableInputs.first(where: { !$0.portType.isOutputOnly }) {
      return assess(port: capturable)
    }
    if let outputOnly = availableInputs.first {
      return RouteHealthAssessment(
        health: .unsuitableOutputOnly,
        primaryInputName: outputOnly.portName,
        primaryInputTypeRaw: outputOnly.portType.rawValue
      )
    }
    return RouteHealthAssessment(health: .noInput)
  }

  private static func assess(port: PortSnapshot) -> RouteHealthAssessment {
    let name = port.portName
    let typeRaw = port.portType.rawValue

    switch port.portType {
    case .lineIn, .usbAudio, .headsetMic, .carAudio, .bluetoothHFP, .bluetoothLE:
      return RouteHealthAssessment(
        health: .suitableExternal,
        primaryInputName: name,
        primaryInputTypeRaw: typeRaw
      )
    case .builtInMic:
      return RouteHealthAssessment(
        health: .cautionBuiltIn,
        primaryInputName: name,
        primaryInputTypeRaw: typeRaw
      )
    case .airPlay, .bluetoothA2DP, .builtInSpeaker, .headphones, .hdmi:
      return RouteHealthAssessment(
        health: .unsuitableOutputOnly,
        primaryInputName: name,
        primaryInputTypeRaw: typeRaw
      )
    case .unknown:
      return RouteHealthAssessment(
        health: .unknownExternal,
        primaryInputName: name,
        primaryInputTypeRaw: typeRaw
      )
    }
  }
}
