import Foundation
import Testing
@testable import Dspeech

/// Audio-input slice (PRD F5) spec.
///
/// Scope is **what is genuinely host-testable**:
/// 1. Pure domain logic of the architect-frozen value types
///    (`AudioInputServiceProtocol.swift`).
/// 2. The frozen `AudioInputService` *contract* every conformer must honour,
///    exercised through `FakeAVAudioSession` (the architecture-sanctioned fake
///    seam — `docs/architecture-mvp-slice-2026-05-19.md` "Test seams").
///
/// NOT in scope (escalated, see `docs/handoff.md` W3 audio tester block):
/// `AppleAudioInputService` / `AudioRouteChangeObserver` hardwire
/// `AVAudioSession.sharedInstance()` with no fakeable seam, so their AVFoundation
/// enumeration / selection / route-mapping / debounce / cancellation paths are
/// **device-only** — they cannot be unit-tested on the host without an impl
/// change introducing a fakeable Core seam.
struct AudioInputServiceTests {

    // MARK: - AudioInputLevel.normalized (pure; architecture-named property test)

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

    // MARK: - Frozen AudioInputService contract (via the sanctioned fake seam)

    @Test func contractSurfacesNoInputsAvailableAsErrorNotEmptyCollection() {
        let service: any AudioInputService = FakeAVAudioSession(scriptedInputs: [])
        do {
            _ = try service.availableInputs()
            Issue.record("availableInputs() must throw .noInputsAvailable, never return []")
        } catch {
            #expect(error == .noInputsAvailable)
        }
    }

    @Test func contractTreatsNilCurrentInputAsLegalPreConfigurationState() {
        let service: any AudioInputService = FakeAVAudioSession(scriptedInputs: [])
        #expect(service.currentInput() == nil)
    }

    @Test func contractRejectsSelectionOfAnUnavailableDescriptor() {
        let present = FakeAVAudioSession.builtInMicDescriptor()
        let stale = FakeAVAudioSession.usbDescriptor(name: "unplugged")
        let fake = FakeAVAudioSession(scriptedInputs: [present])

        do {
            try fake.select(stale)
            Issue.record("select() must reject a descriptor absent from availableInputs")
        } catch {
            #expect(error == .inputNotSelectable(stale))
        }
        #expect(fake.selectedInput == nil)
    }

    @Test func contractAcceptsSelectionOfAnAvailableDescriptor() throws {
        let usb = FakeAVAudioSession.usbDescriptor()
        let fake = FakeAVAudioSession(scriptedInputs: [usb])

        try fake.select(usb)

        #expect(fake.selectedInput == usb)
        #expect(fake.currentInput() == usb)
    }

    @Test func contractPropagatesActivationFailureFromTheSession() {
        let usb = FakeAVAudioSession.usbDescriptor()
        let fake = FakeAVAudioSession(scriptedInputs: [usb])
        fake.selectError = .activationFailed("session-could-not-activate")

        do {
            try fake.select(usb)
            Issue.record("select() must propagate .activationFailed unchanged")
        } catch {
            #expect(error == .activationFailed("session-could-not-activate"))
        }
    }

    @Test func contractLevelsStreamFinishesOnConsumerCancellation() async {
        let fake = FakeAVAudioSession()
        let consumer = Task {
            for try await _ in fake.levels() {}
        }
        // Give the stream builder a turn so onTermination is registered.
        try? await Task.sleep(nanoseconds: 20_000_000)
        consumer.cancel()

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !fake.levelsStreamTerminated {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(fake.levelsStreamTerminated)
    }
}
