import Foundation
import Testing
@testable import Dspeech

struct RouteHealthClassifierTests {
    private static func port(_ type: AudioPortType, name: String = "X") -> PortSnapshot {
        PortSnapshot(portType: type, portName: name)
    }

    @Test func emptyRouteAndNoInputsIsNoInput() {
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [], outputs: []),
            availableInputs: []
        )
        #expect(result.health == .noInput)
        #expect(result.primaryInputName == nil)
    }

    @Test func builtInMicIsCaution() {
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [Self.port(.builtInMic, name: "iPhone Microphone")]),
            availableInputs: [Self.port(.builtInMic, name: "iPhone Microphone")]
        )
        #expect(result.health == .cautionBuiltIn)
        #expect(result.primaryInputName == "iPhone Microphone")
        #expect(result.primaryInputTypeRaw == "MicrophoneBuiltIn")
    }

    @Test func usbAudioIsSuitableExternal() {
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [Self.port(.usbAudio, name: "Aviation USB Tap")]),
            availableInputs: [Self.port(.usbAudio, name: "Aviation USB Tap")]
        )
        #expect(result.health == .suitableExternal)
        #expect(result.primaryInputName == "Aviation USB Tap")
    }

    @Test func headsetMicIsSuitableExternal() {
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [Self.port(.headsetMic, name: "Wired Headset")]),
            availableInputs: [Self.port(.headsetMic, name: "Wired Headset")]
        )
        #expect(result.health == .suitableExternal)
    }

    @Test func lineInIsSuitableExternal() {
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [Self.port(.lineIn, name: "Line In")]),
            availableInputs: [Self.port(.lineIn, name: "Line In")]
        )
        #expect(result.health == .suitableExternal)
    }

    @Test func bluetoothHFPIsSuitableExternal() {
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [Self.port(.bluetoothHFP, name: "Bose A20")]),
            availableInputs: [Self.port(.bluetoothHFP, name: "Bose A20")]
        )
        #expect(result.health == .suitableExternal)
        #expect(result.primaryInputName == "Bose A20")
    }

    @Test func bluetoothA2DPOnlyAvailableIsUnsuitable() {
        let a2dp = PortSnapshot(portType: .bluetoothA2DP, portName: "AirPods Max")
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [], outputs: [a2dp]),
            availableInputs: [a2dp]
        )
        #expect(result.health == .unsuitableOutputOnly)
        #expect(result.primaryInputName == "AirPods Max")
    }

    @Test func bluetoothA2DPDirectInputIsUnsuitable() {
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [Self.port(.bluetoothA2DP, name: "AirPods")]),
            availableInputs: [Self.port(.bluetoothA2DP, name: "AirPods")]
        )
        #expect(result.health == .unsuitableOutputOnly)
    }

    @Test func unknownPortTypeIsUnknownExternal() {
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [Self.port(.unknown("FutureXR"), name: "FutureXR Mic")]),
            availableInputs: [Self.port(.unknown("FutureXR"), name: "FutureXR Mic")]
        )
        #expect(result.health == .unknownExternal)
        #expect(result.primaryInputTypeRaw == "FutureXR")
    }

    @Test func carAudioIsSuitableExternal() {
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [Self.port(.carAudio, name: "Car Audio")]),
            availableInputs: [Self.port(.carAudio, name: "Car Audio")]
        )
        #expect(result.health == .suitableExternal)
    }

    @Test func portTypeRoundTripPreservesUnknownRaw() {
        let raw = "VendorSpecificMic"
        let type = AudioPortType(rawValue: raw)
        #expect(type.rawValue == raw)
        if case .unknown = type {} else { Issue.record("expected unknown case") }
    }

    @Test func outputOnlyPortsAreNotInputCapable() {
        #expect(AudioPortType.bluetoothA2DP.isOutputOnly)
        #expect(AudioPortType.builtInSpeaker.isOutputOnly)
        #expect(AudioPortType.headphones.isOutputOnly)
        #expect(AudioPortType.hdmi.isOutputOnly)
        #expect(!AudioPortType.builtInMic.isOutputOnly)
        #expect(!AudioPortType.usbAudio.isOutputOnly)
        #expect(!AudioPortType.bluetoothHFP.isOutputOnly)
        #expect(!AudioPortType.bluetoothLE.isOutputOnly)
        #expect(!AudioPortType.headsetMic.isOutputOnly)
        #expect(!AudioPortType.lineIn.isOutputOnly)
        #expect(!AudioPortType.carAudio.isOutputOnly)
        #expect(!AudioPortType.airPlay.isOutputOnly)
        #expect(!AudioPortType.unknown("X").isOutputOnly)
    }

    @Test func builtInSpeakerOnlyAvailableIsUnsuitable() {
        let speaker = PortSnapshot(portType: .builtInSpeaker, portName: "Speaker")
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [], outputs: [speaker]),
            availableInputs: [speaker]
        )
        #expect(result.health == .unsuitableOutputOnly)
        #expect(result.primaryInputName == "Speaker")
        #expect(result.primaryInputTypeRaw == "Speaker")
    }

    @Test func headphonesOnlyAvailableIsUnsuitable() {
        let phones = PortSnapshot(portType: .headphones, portName: "Wired Headphones")
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [], outputs: [phones]),
            availableInputs: [phones]
        )
        #expect(result.health == .unsuitableOutputOnly)
        #expect(result.primaryInputTypeRaw == "Headphones")
    }

    @Test func hdmiOnlyAvailableIsUnsuitable() {
        let hdmi = PortSnapshot(portType: .hdmi, portName: "HDMI")
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [], outputs: [hdmi]),
            availableInputs: [hdmi]
        )
        #expect(result.health == .unsuitableOutputOnly)
        #expect(result.primaryInputTypeRaw == "HDMI")
    }

    @Test func builtInSpeakerAsDirectInputIsUnsuitable() {
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [Self.port(.builtInSpeaker, name: "Speaker")]),
            availableInputs: [Self.port(.builtInSpeaker, name: "Speaker")]
        )
        #expect(result.health == .unsuitableOutputOnly)
    }

    @Test func headphonesAsDirectInputIsUnsuitable() {
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [Self.port(.headphones, name: "Headphones")]),
            availableInputs: [Self.port(.headphones, name: "Headphones")]
        )
        #expect(result.health == .unsuitableOutputOnly)
    }

    @Test func hdmiAsDirectInputIsUnsuitable() {
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [Self.port(.hdmi, name: "HDMI")]),
            availableInputs: [Self.port(.hdmi, name: "HDMI")]
        )
        #expect(result.health == .unsuitableOutputOnly)
    }

    @Test func bluetoothLEIsSuitableExternal_pinningCurrentBehavior() {
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [Self.port(.bluetoothLE, name: "LE Mic")]),
            availableInputs: [Self.port(.bluetoothLE, name: "LE Mic")]
        )
        #expect(result.health == .suitableExternal)
        #expect(result.primaryInputTypeRaw == "BluetoothLE")
    }

    @Test func airPlayIsSuitableExternal_pinningCurrentBehavior() {
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [Self.port(.airPlay, name: "AirPlay Receiver")]),
            availableInputs: [Self.port(.airPlay, name: "AirPlay Receiver")]
        )
        #expect(result.health == .suitableExternal)
        #expect(result.primaryInputTypeRaw == "AirPlay")
    }

    @Test func emptyRouteWithSuitableAvailableInputUsesAvailableInput() {
        let usb = PortSnapshot(portType: .usbAudio, portName: "USB Tap")
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [], outputs: []),
            availableInputs: [usb]
        )
        #expect(result.health == .suitableExternal)
        #expect(result.primaryInputName == "USB Tap")
    }

    @Test func emptyRouteWithBuiltInMicAvailableIsCaution() {
        let mic = PortSnapshot(portType: .builtInMic, portName: "iPhone Microphone")
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [], outputs: []),
            availableInputs: [mic]
        )
        #expect(result.health == .cautionBuiltIn)
        #expect(result.primaryInputName == "iPhone Microphone")
    }

    @Test func emptyRouteWithMixedAvailableInputsPrefersCapturableInput() {
        let usb = PortSnapshot(portType: .usbAudio, portName: "USB Tap")
        let a2dp = PortSnapshot(portType: .bluetoothA2DP, portName: "AirPods")
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [], outputs: [a2dp]),
            availableInputs: [a2dp, usb]
        )
        #expect(result.health == .suitableExternal)
        #expect(result.primaryInputName == "USB Tap")
    }

    @Test func emptyRouteWithOnlyOutputAvailableIsUnsuitable() {
        let a2dp = PortSnapshot(portType: .bluetoothA2DP, portName: "AirPods")
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [], outputs: [a2dp]),
            availableInputs: [a2dp]
        )
        #expect(result.health == .unsuitableOutputOnly)
        #expect(result.primaryInputName == "AirPods")
    }

    @Test func unknownRawValuePreservedThroughAssessment() {
        let raw = "VendorXR-Mic-v2"
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [Self.port(.unknown(raw), name: "XR Mic")]),
            availableInputs: [Self.port(.unknown(raw), name: "XR Mic")]
        )
        #expect(result.health == .unknownExternal)
        #expect(result.primaryInputTypeRaw == raw)
        #expect(result.primaryInputName == "XR Mic")
    }

    @Test func portTypeAliasesMapToHeadsetMic() {
        #expect(AudioPortType(rawValue: "MicrophoneWired") == .headsetMic)
        #expect(AudioPortType(rawValue: "HeadsetMicrophone") == .headsetMic)
        #expect(AudioPortType(rawValue: "Headset Microphone") == .headsetMic)
    }

    @Test func portTypeRawValueRoundTripForAllKnownCases() {
        let cases: [(AudioPortType, String)] = [
            (.builtInMic, "MicrophoneBuiltIn"),
            (.headsetMic, "MicrophoneWired"),
            (.lineIn, "LineIn"),
            (.usbAudio, "USBAudio"),
            (.bluetoothHFP, "BluetoothHFP"),
            (.bluetoothLE, "BluetoothLE"),
            (.carAudio, "CarAudio"),
            (.airPlay, "AirPlay"),
            (.bluetoothA2DP, "BluetoothA2DPOutput"),
            (.builtInSpeaker, "Speaker"),
            (.headphones, "Headphones"),
            (.hdmi, "HDMI")
        ]
        for (type, raw) in cases {
            #expect(type.rawValue == raw)
            #expect(AudioPortType(rawValue: raw) == type)
        }
    }

    @Test func primaryInputIsFirstInputEvenWithMultiple() {
        let usb = Self.port(.usbAudio, name: "USB Tap")
        let builtin = Self.port(.builtInMic, name: "iPhone Mic")
        let result = RouteHealthClassifier.classify(
            route: RouteSnapshot(inputs: [usb, builtin]),
            availableInputs: [usb, builtin]
        )
        #expect(result.health == .suitableExternal)
        #expect(result.primaryInputName == "USB Tap")
        #expect(result.primaryInputTypeRaw == "USBAudio")
    }
}
