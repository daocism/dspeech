import Foundation
import Testing

@testable import Dspeech

// Property-based tests for RouteHealthClassifier — a pure total function from
// (RouteSnapshot, [PortSnapshot]) to RouteHealthAssessment. The classifier's contract:
//   1. route.inputs non-empty -> assess(route.inputs.first) (port-type switch).
//   2. route.inputs empty, a capturable (non-output-only) available input exists -> assess(it).
//   3. route.inputs empty, only output-only available inputs -> .unsuitableOutputOnly (first one).
//   4. route.inputs empty, no available inputs -> .noInput (no name/raw).
// The assess(_:) switch is itself total over AudioPortType; every property below pins one
// branch outcome, plus the cross-cutting invariants (totality, determinism, name/raw fidelity).
// A distinct seeded SeededGenerator drives each property (reused from PropertyTestSupport).

// MARK: - Component generators (file-scope, private — do not edit PropertyTestSupport)

// Port types assess(_:) classifies as .suitableExternal.
private let suitableExternalTypes: [AudioPortType] = [
  .lineIn, .usbAudio, .headsetMic, .carAudio, .bluetoothHFP, .bluetoothLE,
]

// Port types assess(_:) classifies as .unsuitableOutputOnly. Matches AudioPortType.isOutputOnly.
private let outputOnlyTypes: [AudioPortType] = [
  .airPlay, .bluetoothA2DP, .builtInSpeaker, .headphones, .hdmi,
]

// Every concrete (non-.unknown) port type — the full closed set the switch enumerates.
private let knownPortTypes: [AudioPortType] =
  suitableExternalTypes + [.builtInMic] + outputOnlyTypes

private func randomUnknownType(using rng: inout SeededGenerator) -> AudioPortType {
  // Raw strings that AudioPortType(rawValue:) does NOT recognize -> the .unknown branch.
  let raws = ["FutureXR", "VendorMic-9", "BluetoothUltra", "Spatial", "ZZ", "neural-tap"]
  return .unknown(raws.randomElement(using: &rng)!)
}

private func randomKnownType(using rng: inout SeededGenerator) -> AudioPortType {
  knownPortTypes.randomElement(using: &rng)!
}

private func randomAnyType(using rng: inout SeededGenerator) -> AudioPortType {
  Bool.random(using: &rng) ? randomKnownType(using: &rng) : randomUnknownType(using: &rng)
}

private func randomName(using rng: inout SeededGenerator) -> String {
  let names = [
    "iPhone Microphone", "USB Tap", "Bose A20", "AirPods", "Speaker", "HDMI",
    "Line In", "Car Audio", "LE Mic", "", "Receiver 7",
  ]
  return names.randomElement(using: &rng)!
}

private func randomPort(using rng: inout SeededGenerator) -> PortSnapshot {
  PortSnapshot(portType: randomAnyType(using: &rng), portName: randomName(using: &rng))
}

private func randomPorts(using rng: inout SeededGenerator, maxCount: Int) -> [PortSnapshot] {
  let count = Int.random(in: 0...maxCount, using: &rng)
  var ports: [PortSnapshot] = []
  for _ in 0..<count { ports.append(randomPort(using: &rng)) }
  return ports
}

// Expected category for assess(_:) on a single port type. Mirrors the switch — used only to
// pin the per-type mapping (every branch), never to re-implement the classifier under test.
private func expectedAssessHealth(for type: AudioPortType) -> RouteHealth {
  if case .unknown = type { return .unknownExternal }
  if type == .builtInMic { return .cautionBuiltIn }
  if outputOnlyTypes.contains(type) { return .unsuitableOutputOnly }
  return .suitableExternal
}

// MARK: - Properties

struct RouteHealthClassifierPropertyTests {

  // Totality: for ANY route + available inputs the classifier returns one of the five health
  // categories and never traps. Branch coverage: drives all four classify branches at random.
  @Test func classifyIsTotalForArbitraryInput() {
    var rng = SeededGenerator(seed: 0x5A0E_0001)
    let allHealths: Set<RouteHealth> = [
      .suitableExternal, .cautionBuiltIn, .unsuitableOutputOnly, .unknownExternal, .noInput,
    ]
    var exercised = 0
    for _ in 0..<300 {
      let route = RouteSnapshot(
        inputs: randomPorts(using: &rng, maxCount: 3),
        outputs: randomPorts(using: &rng, maxCount: 3))
      let available = randomPorts(using: &rng, maxCount: 4)
      let result = RouteHealthClassifier.classify(route: route, availableInputs: available)
      #expect(allHealths.contains(result.health), "unexpected health: \(result.health)")
      exercised += 1
    }
    #expect(exercised >= 290, "too few cases reached the assertion: \(exercised)")
  }

  // Determinism: identical input yields identical assessment (pure function, no hidden state).
  @Test func classifyIsDeterministic() {
    var rng = SeededGenerator(seed: 0x5A0E_0002)
    var exercised = 0
    for _ in 0..<300 {
      let route = RouteSnapshot(
        inputs: randomPorts(using: &rng, maxCount: 3),
        outputs: randomPorts(using: &rng, maxCount: 3))
      let available = randomPorts(using: &rng, maxCount: 4)
      let first = RouteHealthClassifier.classify(route: route, availableInputs: available)
      let second = RouteHealthClassifier.classify(route: route, availableInputs: available)
      #expect(first == second, "non-deterministic for route \(route)")
      exercised += 1
    }
    #expect(exercised >= 290, "too few cases reached the assertion: \(exercised)")
  }

  // Branch 1 + assess branches: when route.inputs is non-empty the FIRST input alone decides the
  // category (per assess), name == its name, raw == its rawValue. availableInputs are irrelevant.
  @Test func nonEmptyRouteClassifiesFirstInputByType() {
    var rng = SeededGenerator(seed: 0x5A0E_0003)
    var exercised = 0
    for _ in 0..<300 {
      let primary = randomPort(using: &rng)
      let extras = randomPorts(using: &rng, maxCount: 2)
      let route = RouteSnapshot(inputs: [primary] + extras)
      // Independent, possibly-contradictory available inputs must not change the outcome.
      let available = randomPorts(using: &rng, maxCount: 4)
      let result = RouteHealthClassifier.classify(route: route, availableInputs: available)
      #expect(result.health == expectedAssessHealth(for: primary.portType))
      #expect(result.primaryInputName == primary.portName)
      #expect(result.primaryInputTypeRaw == primary.portType.rawValue)
      exercised += 1
    }
    #expect(exercised >= 290, "too few cases reached the assertion: \(exercised)")
  }

  // assess branch A: every suitable-external port type as the primary input -> .suitableExternal.
  @Test func suitableExternalTypesClassifyAsSuitableExternal() {
    var rng = SeededGenerator(seed: 0x5A0E_0004)
    var exercised = 0
    for _ in 0..<300 {
      let type = suitableExternalTypes.randomElement(using: &rng)!
      let port = PortSnapshot(portType: type, portName: randomName(using: &rng))
      let result = RouteHealthClassifier.classify(
        route: RouteSnapshot(inputs: [port]), availableInputs: [port])
      #expect(result.health == .suitableExternal, "type \(type.rawValue)")
      #expect(result.primaryInputTypeRaw == type.rawValue)
      exercised += 1
    }
    #expect(exercised >= 290, "too few cases reached the assertion: \(exercised)")
  }

  // assess branch B: built-in mic as the primary input -> .cautionBuiltIn, never suitable.
  @Test func builtInMicClassifiesAsCaution() {
    var rng = SeededGenerator(seed: 0x5A0E_0005)
    var exercised = 0
    for _ in 0..<300 {
      let port = PortSnapshot(portType: .builtInMic, portName: randomName(using: &rng))
      let result = RouteHealthClassifier.classify(
        route: RouteSnapshot(inputs: [port]), availableInputs: [port])
      #expect(result.health == .cautionBuiltIn)
      #expect(result.health != .suitableExternal)
      #expect(result.primaryInputTypeRaw == "MicrophoneBuiltIn")
      exercised += 1
    }
    #expect(exercised >= 290, "too few cases reached the assertion: \(exercised)")
  }

  // assess branch C: every output-only port type as the primary input -> .unsuitableOutputOnly.
  @Test func outputOnlyTypesClassifyAsUnsuitable() {
    var rng = SeededGenerator(seed: 0x5A0E_0006)
    var exercised = 0
    for _ in 0..<300 {
      let type = outputOnlyTypes.randomElement(using: &rng)!
      let port = PortSnapshot(portType: type, portName: randomName(using: &rng))
      let result = RouteHealthClassifier.classify(
        route: RouteSnapshot(inputs: [port]), availableInputs: [port])
      #expect(result.health == .unsuitableOutputOnly, "type \(type.rawValue)")
      #expect(result.primaryInputTypeRaw == type.rawValue)
      exercised += 1
    }
    #expect(exercised >= 290, "too few cases reached the assertion: \(exercised)")
  }

  // assess branch D: any unrecognized port type as the primary input -> .unknownExternal, and the
  // raw string is preserved verbatim through the assessment.
  @Test func unknownTypeClassifiesAsUnknownExternalPreservingRaw() {
    var rng = SeededGenerator(seed: 0x5A0E_0007)
    var exercised = 0
    for _ in 0..<300 {
      let type = randomUnknownType(using: &rng)
      let port = PortSnapshot(portType: type, portName: randomName(using: &rng))
      let result = RouteHealthClassifier.classify(
        route: RouteSnapshot(inputs: [port]), availableInputs: [port])
      #expect(result.health == .unknownExternal)
      #expect(result.primaryInputTypeRaw == type.rawValue)
      #expect(result.primaryInputName == port.portName)
      exercised += 1
    }
    #expect(exercised >= 290, "too few cases reached the assertion: \(exercised)")
  }

  // Branch 4: empty route AND no available inputs -> .noInput with no name/raw. The only branch
  // that yields nil identity fields.
  @Test func emptyRouteAndNoAvailableInputsIsNoInput() {
    var rng = SeededGenerator(seed: 0x5A0E_0008)
    var exercised = 0
    for _ in 0..<300 {
      // Outputs are irrelevant to classify; randomize them to prove they never feed the decision.
      let route = RouteSnapshot(inputs: [], outputs: randomPorts(using: &rng, maxCount: 3))
      let result = RouteHealthClassifier.classify(route: route, availableInputs: [])
      #expect(result.health == .noInput)
      #expect(result.primaryInputName == nil)
      #expect(result.primaryInputTypeRaw == nil)
      exercised += 1
    }
    #expect(exercised >= 290, "too few cases reached the assertion: \(exercised)")
  }

  // Branch 2: empty route, at least one capturable (non-output-only) available input exists. The
  // classifier assesses the FIRST capturable input by type and reports a non-.noInput,
  // non-nil-named assessment. We only assert the conservative facts the contract guarantees: a
  // capturable input is chosen, so health is never .noInput and name/raw are non-nil.
  @Test func emptyRouteWithCapturableAvailableInputAssessesACapturablePort() {
    var rng = SeededGenerator(seed: 0x5A0E_0009)
    var exercised = 0
    for _ in 0..<300 {
      // Build available inputs with >=1 capturable port at a random position.
      var available = randomPorts(using: &rng, maxCount: 3)
      let capturableType =
        Bool.random(using: &rng)
        ? suitableExternalTypes.randomElement(using: &rng)!
        : .builtInMic
      let capturable = PortSnapshot(
        portType: capturableType, portName: randomName(using: &rng))
      let insertAt = Int.random(in: 0...available.count, using: &rng)
      available.insert(capturable, at: insertAt)

      let result = RouteHealthClassifier.classify(
        route: RouteSnapshot(inputs: [], outputs: []), availableInputs: available)

      // The first non-output-only available input is the one assessed.
      let firstCapturable = available.first { !$0.portType.isOutputOnly }!
      #expect(result.health != .noInput)
      #expect(result.health == expectedAssessHealth(for: firstCapturable.portType))
      #expect(result.primaryInputName == firstCapturable.portName)
      #expect(result.primaryInputTypeRaw == firstCapturable.portType.rawValue)
      exercised += 1
    }
    #expect(exercised >= 290, "too few cases reached the assertion: \(exercised)")
  }

  // Branch 3: empty route, available inputs ALL output-only -> .unsuitableOutputOnly, named after
  // the FIRST available port. Distinguishes branch 3 (output-only available) from branch 4 (none).
  @Test func emptyRouteWithOnlyOutputOnlyAvailableIsUnsuitableNamedFirst() {
    var rng = SeededGenerator(seed: 0x5A0E_000A)
    var exercised = 0
    for _ in 0..<300 {
      let count = Int.random(in: 1...4, using: &rng)
      var available: [PortSnapshot] = []
      for _ in 0..<count {
        let type = outputOnlyTypes.randomElement(using: &rng)!
        available.append(PortSnapshot(portType: type, portName: randomName(using: &rng)))
      }
      let result = RouteHealthClassifier.classify(
        route: RouteSnapshot(inputs: [], outputs: []), availableInputs: available)
      let first = available.first!
      #expect(result.health == .unsuitableOutputOnly)
      #expect(result.primaryInputName == first.portName)
      #expect(result.primaryInputTypeRaw == first.portType.rawValue)
      exercised += 1
    }
    #expect(exercised >= 290, "too few cases reached the assertion: \(exercised)")
  }

  // Whenever the classifier reports a port (health != .noInput), BOTH identity fields are non-nil;
  // when it reports .noInput, BOTH are nil. No partially-populated assessment escapes.
  @Test func identityFieldsArePresentExactlyWhenNotNoInput() {
    var rng = SeededGenerator(seed: 0x5A0E_000B)
    var exercised = 0
    for _ in 0..<300 {
      let route = RouteSnapshot(
        inputs: randomPorts(using: &rng, maxCount: 2),
        outputs: randomPorts(using: &rng, maxCount: 2))
      let available = randomPorts(using: &rng, maxCount: 4)
      let result = RouteHealthClassifier.classify(route: route, availableInputs: available)
      if result.health == .noInput {
        #expect(result.primaryInputName == nil)
        #expect(result.primaryInputTypeRaw == nil)
      } else {
        #expect(result.primaryInputName != nil)
        #expect(result.primaryInputTypeRaw != nil)
      }
      exercised += 1
    }
    #expect(exercised >= 290, "too few cases reached the assertion: \(exercised)")
  }

  // .noInput is reachable ONLY when there is no usable input anywhere: route.inputs empty AND
  // availableInputs empty. Any non-empty input list precludes .noInput. (Negative invariant for
  // branches 1-3 vs branch 4.)
  @Test func noInputImpliesNoInputsAnywhere() {
    var rng = SeededGenerator(seed: 0x5A0E_000C)
    var exercised = 0
    for _ in 0..<300 {
      let route = RouteSnapshot(
        inputs: randomPorts(using: &rng, maxCount: 3),
        outputs: randomPorts(using: &rng, maxCount: 3))
      let available = randomPorts(using: &rng, maxCount: 4)
      let result = RouteHealthClassifier.classify(route: route, availableInputs: available)
      if !route.inputs.isEmpty || !available.isEmpty {
        #expect(result.health != .noInput, "noInput despite present inputs")
      }
      exercised += 1
    }
    #expect(exercised >= 290, "too few cases reached the assertion: \(exercised)")
  }

  // Outputs in the route never influence the assessment: for any fixed route.inputs +
  // availableInputs, swapping route.outputs leaves the result unchanged.
  @Test func routeOutputsDoNotAffectClassification() {
    var rng = SeededGenerator(seed: 0x5A0E_000D)
    var exercised = 0
    for _ in 0..<300 {
      let inputs = randomPorts(using: &rng, maxCount: 3)
      let available = randomPorts(using: &rng, maxCount: 4)
      let outputsA = randomPorts(using: &rng, maxCount: 3)
      let outputsB = randomPorts(using: &rng, maxCount: 3)
      let resultA = RouteHealthClassifier.classify(
        route: RouteSnapshot(inputs: inputs, outputs: outputsA), availableInputs: available)
      let resultB = RouteHealthClassifier.classify(
        route: RouteSnapshot(inputs: inputs, outputs: outputsB), availableInputs: available)
      #expect(resultA == resultB, "route outputs altered the assessment")
      exercised += 1
    }
    #expect(exercised >= 290, "too few cases reached the assertion: \(exercised)")
  }

  // Branch 2 with an UNKNOWN capturable: an empty route whose first capturable available input is a
  // .unknown type is assessed as .unknownExternal, carrying its raw identity. Reaches the .unknown
  // branch via the availableInputs-first-capturable path, not just in isolation.
  @Test func emptyRouteWithUnknownCapturableInputIsUnknownExternal() {
    var rng = SeededGenerator(seed: 0x5A0E_0010)
    var exercised = 0
    for _ in 0..<300 {
      let unknown = PortSnapshot(
        portType: randomUnknownType(using: &rng), portName: randomName(using: &rng))
      var available = [unknown]
      available.append(contentsOf: randomPorts(using: &rng, maxCount: 3))
      let route = RouteSnapshot(inputs: [], outputs: randomPorts(using: &rng, maxCount: 2))
      let result = RouteHealthClassifier.classify(route: route, availableInputs: available)
      #expect(result.health == .unknownExternal)
      #expect(result.primaryInputName == unknown.portName)
      #expect(result.primaryInputTypeRaw == unknown.portType.rawValue)
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }
}
