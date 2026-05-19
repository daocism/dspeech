import Foundation
import Testing
@testable import Dspeech

/// Audio-input slice (PRD F5) behavioural spec.
///
/// Two layers:
/// 1. Frozen-contract value types (`AudioInputServiceProtocol.swift`) — green
///    from the first commit, regression cover for the architect-frozen surface.
/// 2. `AppleAudioInputService` over `FakeAVAudioSession` — RED until the W3
///    audio implementer lands the concrete + the `AudioInputSessionPort` seam,
///    then green with no test edits (TDD red → green).
struct AudioInputServiceTests {

    // MARK: - AudioInputLevel.normalized (pure domain logic — green from start)

    @Test(arguments: [Float(-60), -75, -120, -.infinity])
    func normalizedIsZeroAtOrBelowFloor(averagePowerDB: Float) {
        let level = AudioInputLevel(averagePowerDB: averagePowerDB, peakPowerDB: averagePowerDB)
        #expect(level.normalized == 0)
    }

    @Test(arguments: [Float(0), 3, 12])
    func normalizedIsOneAtOrAboveCeiling(averagePowerDB: Float) {
        let level = AudioInputLevel(averagePowerDB: averagePowerDB, peakPowerDB: 0)
        #expect(level.normalized == 1)
    }

    @Test func normalizedMapsMidpointToHalf() {
        let level = AudioInputLevel(averagePowerDB: -30, peakPowerDB: -10)
        #expect(abs(level.normalized - 0.5) < 0.0001)
    }

    @Test(arguments: [
        (Float(-50), Float(-40)),
        (Float(-40), Float(-20)),
        (Float(-20), Float(-5)),
        (Float(-59), Float(-1)),
    ])
    func normalizedIsMonotonicInAveragePower(lower: Float, higher: Float) {
        let quiet = AudioInputLevel(averagePowerDB: lower, peakPowerDB: lower)
        let loud = AudioInputLevel(averagePowerDB: higher, peakPowerDB: higher)
        #expect(quiet.normalized < loud.normalized)
    }

    @Test(arguments: stride(from: Float(-80), through: 20, by: 3.5).map { $0 })
    func normalizedIsAlwaysBoundedToUnitInterval(averagePowerDB: Float) {
        let level = AudioInputLevel(averagePowerDB: averagePowerDB, peakPowerDB: averagePowerDB)
        #expect(level.normalized >= 0)
        #expect(level.normalized <= 1)
    }

    // MARK: - AudioInputDescriptor (Codable round-trip — CLAUDE.md persistence rule)

    @Test func descriptorSurvivesCodableRoundTrip() throws {
        let original = AudioInputDescriptor(
            id: "usb-c-uid-42",
            kind: .wired,
            displayName: "Class-Compliant USB-C Interface",
            portType: "USBAudio"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioInputDescriptor.self, from: data)
        #expect(decoded == original)
        #expect(decoded.id == "usb-c-uid-42")
        #expect(decoded.kind == .wired)
    }

    @Test func descriptorIdentityIsPortUID() {
        let a = AudioInputDescriptor(id: "uid-1", kind: .wired, displayName: "X", portType: "USBAudio")
        let b = AudioInputDescriptor(id: "uid-1", kind: .bluetooth, displayName: "Y", portType: "BluetoothHFP")
        #expect(a.id == b.id)
        #expect(a != b)
    }

    // MARK: - AudioInputKind (bucket completeness)

    @Test func kindCoversExactlyTheFourPickerBuckets() {
        #expect(Set(AudioInputKind.allCases) == [.builtInMicrophone, .wired, .bluetooth, .other])
        #expect(AudioInputKind.allCases.count == 4)
    }

    // MARK: - AudioInputServiceError (Equatable across all five cases)

    @Test func errorEquatableDistinguishesEveryCase() {
        let descriptor = FakeAVAudioSession.usbDescriptor()
        let cases: [AudioInputServiceError] = [
            .audioSessionUnavailable("a"),
            .noInputsAvailable,
            .inputNotSelectable(descriptor),
            .activationFailed("b"),
            .meteringUnavailable("c"),
        ]
        for (i, lhs) in cases.enumerated() {
            for (j, rhs) in cases.enumerated() {
                #expect((lhs == rhs) == (i == j))
            }
        }
    }

    @Test func errorEquatableIsSensitiveToAssociatedValues() {
        #expect(AudioInputServiceError.activationFailed("denied") != .activationFailed("busy"))
        let usb = FakeAVAudioSession.usbDescriptor()
        let bt = FakeAVAudioSession.bluetoothDescriptor()
        #expect(AudioInputServiceError.inputNotSelectable(usb) != .inputNotSelectable(bt))
    }

    // MARK: - AppleAudioInputService over FakeAVAudioSession (RED until W3 impl)

    @Test func availableInputsReturnsSessionEnumeratedDescriptors() throws {
        let usb = FakeAVAudioSession.usbDescriptor()
        let builtIn = FakeAVAudioSession.builtInMicDescriptor()
        let fake = FakeAVAudioSession(scriptedInputs: [usb, builtIn])
        let service = AppleAudioInputService(session: fake)

        let inputs = try service.availableInputs()

        #expect(inputs == [usb, builtIn])
    }

    @Test func availableInputsThrowsNoInputsAvailableWhenSessionEmpty() {
        let fake = FakeAVAudioSession(scriptedInputs: [])
        let service = AppleAudioInputService(session: fake)

        do {
            _ = try service.availableInputs()
            Issue.record("expected AudioInputServiceError.noInputsAvailable")
        } catch {
            #expect(error == .noInputsAvailable)
        }
    }

    @Test func availableInputsRethrowsAudioSessionUnavailableWhenPermissionDenied() {
        let fake = FakeAVAudioSession(scriptedInputs: [])
        fake.availableInputsError = .audioSessionUnavailable("record-permission-denied")
        let service = AppleAudioInputService(session: fake)

        do {
            _ = try service.availableInputs()
            Issue.record("expected AudioInputServiceError.audioSessionUnavailable")
        } catch {
            #expect(error == .audioSessionUnavailable("record-permission-denied"))
        }
    }

    @Test func currentInputIsNilBeforeSessionConfigured() {
        let fake = FakeAVAudioSession(scriptedInputs: [], scriptedCurrentInput: nil)
        let service = AppleAudioInputService(session: fake)
        #expect(service.currentInput() == nil)
    }

    @Test func selectForwardsPresentDescriptorToSession() throws {
        let usb = FakeAVAudioSession.usbDescriptor()
        let fake = FakeAVAudioSession(scriptedInputs: [usb])
        let service = AppleAudioInputService(session: fake)

        try service.select(usb)

        #expect(fake.lastPreferredInput == usb)
        #expect(service.currentInput() == usb)
    }

    @Test func selectThrowsInputNotSelectableWhenDescriptorAbsent() {
        let present = FakeAVAudioSession.builtInMicDescriptor()
        let stale = FakeAVAudioSession.usbDescriptor(name: "unplugged")
        let fake = FakeAVAudioSession(scriptedInputs: [present])
        let service = AppleAudioInputService(session: fake)

        do {
            try service.select(stale)
            Issue.record("expected AudioInputServiceError.inputNotSelectable")
        } catch {
            #expect(error == .inputNotSelectable(stale))
        }
        #expect(fake.lastPreferredInput == nil)
    }

    @Test func selectRethrowsActivationFailedFromSession() {
        let usb = FakeAVAudioSession.usbDescriptor()
        let fake = FakeAVAudioSession(scriptedInputs: [usb])
        fake.setPreferredError = .activationFailed("session-could-not-activate")
        let service = AppleAudioInputService(session: fake)

        do {
            try service.select(usb)
            Issue.record("expected AudioInputServiceError.activationFailed")
        } catch {
            #expect(error == .activationFailed("session-could-not-activate"))
        }
    }
}
