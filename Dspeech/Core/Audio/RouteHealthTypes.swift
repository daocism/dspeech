import Foundation

enum AudioPortType: Equatable, Sendable {
  case builtInMic
  case headsetMic
  case lineIn
  case usbAudio
  case bluetoothHFP
  case bluetoothLE
  case carAudio
  case airPlay
  case bluetoothA2DP
  case builtInSpeaker
  case headphones
  case hdmi
  case unknown(String)

  init(rawValue: String) {
    switch rawValue {
    case "MicrophoneBuiltIn": self = .builtInMic
    case "MicrophoneWired", "HeadsetMicrophone", "Headset Microphone": self = .headsetMic
    case "LineIn": self = .lineIn
    case "USBAudio": self = .usbAudio
    case "BluetoothHFP": self = .bluetoothHFP
    case "BluetoothLE": self = .bluetoothLE
    case "CarAudio": self = .carAudio
    case "AirPlay": self = .airPlay
    case "BluetoothA2DPOutput": self = .bluetoothA2DP
    case "Speaker": self = .builtInSpeaker
    case "Headphones": self = .headphones
    case "HDMI": self = .hdmi
    default: self = .unknown(rawValue)
    }
  }

  var rawValue: String {
    switch self {
    case .builtInMic: return "MicrophoneBuiltIn"
    case .headsetMic: return "MicrophoneWired"
    case .lineIn: return "LineIn"
    case .usbAudio: return "USBAudio"
    case .bluetoothHFP: return "BluetoothHFP"
    case .bluetoothLE: return "BluetoothLE"
    case .carAudio: return "CarAudio"
    case .airPlay: return "AirPlay"
    case .bluetoothA2DP: return "BluetoothA2DPOutput"
    case .builtInSpeaker: return "Speaker"
    case .headphones: return "Headphones"
    case .hdmi: return "HDMI"
    case .unknown(let raw): return raw
    }
  }

  var isOutputOnly: Bool {
    switch self {
    case .airPlay, .bluetoothA2DP, .builtInSpeaker, .headphones, .hdmi: return true
    default: return false
    }
  }
}

struct PortSnapshot: Equatable, Sendable {
  let portType: AudioPortType
  let portName: String
  let uid: String

  init(
    portType: AudioPortType,
    portName: String,
    uid: String = ""
  ) {
    self.portType = portType
    self.portName = portName
    self.uid = uid
  }
}

struct RouteSnapshot: Equatable, Sendable {
  let inputs: [PortSnapshot]
  let outputs: [PortSnapshot]

  init(inputs: [PortSnapshot] = [], outputs: [PortSnapshot] = []) {
    self.inputs = inputs
    self.outputs = outputs
  }
}

enum RouteHealth: String, Equatable, Sendable {
  case suitableExternal
  case cautionBuiltIn
  case unsuitableOutputOnly
  case unknownExternal
  case noInput
}

struct RouteHealthAssessment: Equatable, Sendable {
  let health: RouteHealth
  let primaryInputName: String?
  let primaryInputTypeRaw: String?

  init(health: RouteHealth, primaryInputName: String? = nil, primaryInputTypeRaw: String? = nil) {
    self.health = health
    self.primaryInputName = primaryInputName
    self.primaryInputTypeRaw = primaryInputTypeRaw
  }
}

enum RouteChangeEvent: Equatable, Sendable {
  case newDeviceAvailable
  case oldDeviceUnavailable
  case categoryChange
  case override
  case wakeFromSleep
  case noSuitableRouteForCategory
  case routeConfigurationChange
  case interruptionBegan
  case interruptionEnded(shouldResume: Bool)
  case mediaServicesWereReset
  case unknown(Int)
}

struct RouteChangeNotice: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case improved
    case lost
    case noSuitableRoute
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case mediaServicesReset
    case silent
  }

  let kind: Kind
  let portName: String?
  let timestamp: Date
}
