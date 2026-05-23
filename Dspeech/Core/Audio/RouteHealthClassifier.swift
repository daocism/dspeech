import Foundation

enum RouteHealthClassifier {
    static func classify(
        route: RouteSnapshot,
        availableInputs: [PortSnapshot]
    ) -> RouteHealthAssessment {
        guard let primary = route.inputs.first else {
            if availableInputs.isEmpty {
                return RouteHealthAssessment(health: .noInput)
            }
            if availableInputs.allSatisfy({ $0.portType.isOutputOnly }) {
                let outputName = availableInputs.first?.portName
                return RouteHealthAssessment(
                    health: .unsuitableOutputOnly,
                    primaryInputName: outputName,
                    primaryInputTypeRaw: availableInputs.first?.portType.rawValue
                )
            }
            return RouteHealthAssessment(health: .noInput)
        }

        let name = primary.portName
        let typeRaw = primary.portType.rawValue

        switch primary.portType {
        case .lineIn, .usbAudio, .headsetMic, .carAudio, .bluetoothHFP, .bluetoothLE, .airPlay:
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
        case .bluetoothA2DP, .builtInSpeaker, .headphones, .hdmi:
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
