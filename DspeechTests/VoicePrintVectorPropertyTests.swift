import Foundation
import Testing

@testable import Dspeech

// Property-based tests for VoicePrintVector's validating initializer and Codable round-trip. A
// seeded PRNG (reused from PropertyTestSupport) makes every counterexample reproducible. The
// invariants enumerate EVERY branch of `init(validatingValues:quality:)`: the success path (all
// finite -> constructs, fields preserved), the `nonFiniteValue(index:)` throw (a single injected
// non-finite value at the first non-finite index), and the `nonFiniteQuality` throw (finite values
// + non-finite quality). The encode/decode path shares the same validating init, so a finite vector
// must survive a JSON round-trip unchanged.

// MARK: - Component-specific generators

private let nonFiniteFloats: [Float] = [
  .nan, .signalingNaN, .infinity, -.infinity,
]

private func randomFiniteFloat(using rng: inout SeededGenerator) -> Float {
  // Spread across small, large, fractional, negative, and exactly-zero finite magnitudes.
  let scale = [Float(1), 10, 100, 1000, 0.001, 0.01]
    .randomElement(using: &rng)!
  let raw = Float(Int.random(in: -1000...1000, using: &rng)) / 1000
  return raw * scale
}

private func randomFiniteValues(using rng: inout SeededGenerator) -> [Float] {
  let count = Int.random(in: 0...12, using: &rng)
  var values: [Float] = []
  for _ in 0..<count { values.append(randomFiniteFloat(using: &rng)) }
  return values
}

private func randomNonFiniteFloat(using rng: inout SeededGenerator) -> Float {
  nonFiniteFloats.randomElement(using: &rng)!
}

struct VoicePrintVectorPropertyTests {

  // MARK: - Success branch

  // Any all-finite (values, quality) constructs via the validating init and preserves both fields
  // and the derived dimension exactly — the happy path that every decode also routes through.
  @Test func allFiniteInputConstructsAndPreservesFields() throws {
    var rng = SeededGenerator(seed: 0x501D_0001)
    var exercised = 0
    for _ in 0..<300 {
      let values = randomFiniteValues(using: &rng)
      let quality = randomFiniteFloat(using: &rng)
      let vector = try VoicePrintVector(validatingValues: values, quality: quality)
      #expect(vector.values == values, "values not preserved: \(values)")
      #expect(vector.quality == quality, "quality not preserved: \(quality)")
      #expect(vector.dimension == values.count, "dimension != count for: \(values)")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // The validating init and the non-throwing memberwise init agree on the constructed value for any
  // all-finite input — validation does not alter accepted fields.
  @Test func validatingInitMatchesMemberwiseInitForFiniteInput() throws {
    var rng = SeededGenerator(seed: 0x501D_0002)
    var exercised = 0
    for _ in 0..<300 {
      let values = randomFiniteValues(using: &rng)
      let quality = randomFiniteFloat(using: &rng)
      let validated = try VoicePrintVector(validatingValues: values, quality: quality)
      let memberwise = VoicePrintVector(values: values, quality: quality)
      #expect(validated == memberwise, "validating init diverged for: \(values) q=\(quality)")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // MARK: - nonFiniteValue(index:) throw branch

  // Injecting EXACTLY ONE non-finite value into an otherwise-finite array makes the validating init
  // throw nonFiniteValue at THAT index — the only non-finite slot is the first one, so the loop's
  // first-match index equals the injected index. Quality is finite so this throw fires before the
  // quality guard.
  @Test func singleInjectedNonFiniteValueThrowsAtThatIndex() {
    var rng = SeededGenerator(seed: 0x501D_0003)
    var exercised = 0
    for _ in 0..<300 {
      var values = randomFiniteValues(using: &rng)
      if values.isEmpty { values = [randomFiniteFloat(using: &rng)] }
      let index = Int.random(in: 0..<values.count, using: &rng)
      values[index] = randomNonFiniteFloat(using: &rng)
      let quality = randomFiniteFloat(using: &rng)
      do {
        _ = try VoicePrintVector(validatingValues: values, quality: quality)
        Issue.record("expected nonFiniteValue throw for injected index \(index)")
      } catch let error as VoicePrintVectorError {
        #expect(
          error == .nonFiniteValue(index: index),
          "expected nonFiniteValue(index: \(index)), got \(error)")
      } catch {
        #expect(Bool(false), "expected VoicePrintVectorError, got \(error)")
      }
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // When MULTIPLE non-finite values are present, the init reports the FIRST (smallest) non-finite
  // index — the loop short-circuits on first match. Pins the loop's early-return ordering.
  @Test func multipleNonFiniteValuesThrowAtFirstIndex() {
    var rng = SeededGenerator(seed: 0x501D_0004)
    var exercised = 0
    for _ in 0..<300 {
      var values = randomFiniteValues(using: &rng)
      while values.count < 2 { values.append(randomFiniteFloat(using: &rng)) }
      let first = Int.random(in: 0..<(values.count - 1), using: &rng)
      let second = Int.random(in: (first + 1)..<values.count, using: &rng)
      values[first] = randomNonFiniteFloat(using: &rng)
      values[second] = randomNonFiniteFloat(using: &rng)
      let quality = randomFiniteFloat(using: &rng)
      do {
        _ = try VoicePrintVector(validatingValues: values, quality: quality)
        Issue.record("expected nonFiniteValue throw, first non-finite at \(first)")
      } catch let error as VoicePrintVectorError {
        #expect(
          error == .nonFiniteValue(index: first),
          "expected first index \(first), got \(error)")
      } catch {
        #expect(Bool(false), "expected VoicePrintVectorError, got \(error)")
      }
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // MARK: - nonFiniteQuality throw branch

  // All-finite values + a non-finite quality throws nonFiniteQuality — the quality guard is only
  // reached once the values loop completes without throwing.
  @Test func nonFiniteQualityWithFiniteValuesThrowsNonFiniteQuality() {
    var rng = SeededGenerator(seed: 0x501D_0005)
    var exercised = 0
    for _ in 0..<300 {
      let values = randomFiniteValues(using: &rng)
      let quality = randomNonFiniteFloat(using: &rng)
      do {
        _ = try VoicePrintVector(validatingValues: values, quality: quality)
        Issue.record("expected nonFiniteQuality throw for quality \(quality)")
      } catch let error as VoicePrintVectorError {
        #expect(error == .nonFiniteQuality, "expected nonFiniteQuality, got \(error)")
      } catch {
        #expect(Bool(false), "expected VoicePrintVectorError, got \(error)")
      }
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // Branch ordering: when BOTH a value and the quality are non-finite, the values-loop throw
  // wins — nonFiniteValue is reported, never nonFiniteQuality (the guard is unreachable).
  @Test func nonFiniteValueTakesPrecedenceOverNonFiniteQuality() {
    var rng = SeededGenerator(seed: 0x501D_0006)
    var exercised = 0
    for _ in 0..<300 {
      var values = randomFiniteValues(using: &rng)
      if values.isEmpty { values = [randomFiniteFloat(using: &rng)] }
      let index = Int.random(in: 0..<values.count, using: &rng)
      values[index] = randomNonFiniteFloat(using: &rng)
      let quality = randomNonFiniteFloat(using: &rng)
      do {
        _ = try VoicePrintVector(validatingValues: values, quality: quality)
        Issue.record("expected nonFiniteValue throw at \(index)")
      } catch let error as VoicePrintVectorError {
        #expect(
          error == .nonFiniteValue(index: index),
          "expected nonFiniteValue(index: \(index)) to win, got \(error)")
      } catch {
        #expect(Bool(false), "expected VoicePrintVectorError, got \(error)")
      }
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // MARK: - Codable round-trip (decode routes through the validating init)

  // A valid (all-finite) vector survives a JSON encode/decode round-trip unchanged. The decoder
  // re-runs the validating init, so this also exercises the success branch via the Codable path.
  @Test func validVectorSurvivesJSONRoundTrip() throws {
    var rng = SeededGenerator(seed: 0x501D_0007)
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    var exercised = 0
    for _ in 0..<300 {
      let values = randomFiniteValues(using: &rng)
      let quality = randomFiniteFloat(using: &rng)
      let original = try VoicePrintVector(validatingValues: values, quality: quality)
      let data = try encoder.encode(original)
      let decoded = try decoder.decode(VoicePrintVector.self, from: data)
      #expect(decoded == original, "round-trip mismatch for: \(values) q=\(quality)")
      #expect(decoded.values == values, "values changed across round-trip: \(values)")
      #expect(decoded.quality == quality, "quality changed across round-trip: \(quality)")
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // Decoding JSON with a non-finite value throws nonFiniteValue at the first non-finite index —
  // the decode path's validating init rejects it exactly like the direct initializer.
  @Test func decodeRejectsNonFiniteValueAtFirstIndex() throws {
    var rng = SeededGenerator(seed: 0x501D_0008)
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let token = "NaN"
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
      positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: token)
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: token)
    var exercised = 0
    for _ in 0..<300 {
      var values = randomFiniteValues(using: &rng)
      if values.isEmpty { values = [randomFiniteFloat(using: &rng)] }
      let index = Int.random(in: 0..<values.count, using: &rng)
      values[index] = randomNonFiniteFloat(using: &rng)
      let payload = VoicePrintVector(values: values, quality: randomFiniteFloat(using: &rng))
      let data = try encoder.encode(payload)
      do {
        _ = try decoder.decode(VoicePrintVector.self, from: data)
        Issue.record("expected decode to throw nonFiniteValue at \(index)")
      } catch let error as VoicePrintVectorError {
        #expect(
          error == .nonFiniteValue(index: index),
          "expected nonFiniteValue(index: \(index)) on decode, got \(error)")
      } catch {
        #expect(Bool(false), "expected VoicePrintVectorError on decode, got \(error)")
      }
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // Decoding JSON with finite values but a non-finite quality throws nonFiniteQuality — the
  // decode path enforces the same quality guard as the direct validating init.
  @Test func decodeRejectsNonFiniteQuality() throws {
    var rng = SeededGenerator(seed: 0x501D_0009)
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let token = "NaN"
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
      positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: token)
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: token)
    var exercised = 0
    for _ in 0..<300 {
      let values = randomFiniteValues(using: &rng)
      let payload = VoicePrintVector(values: values, quality: randomNonFiniteFloat(using: &rng))
      let data = try encoder.encode(payload)
      do {
        _ = try decoder.decode(VoicePrintVector.self, from: data)
        Issue.record("expected decode to throw nonFiniteQuality")
      } catch let error as VoicePrintVectorError {
        #expect(error == .nonFiniteQuality, "expected nonFiniteQuality on decode, got \(error)")
      } catch {
        #expect(Bool(false), "expected VoicePrintVectorError on decode, got \(error)")
      }
      exercised += 1
    }
    #expect(exercised >= 300, "too few cases reached the assertion: \(exercised)")
  }

  // init(from:) propagates structural Codable failures (missing key / wrong type) rather than
  // swallowing them — fail-fast at the decode boundary. (Reviewer gap: init(from:) decode-error
  // paths, distinct from the non-finite validation throws above.)
  @Test func decodeRejectsStructurallyMalformedJSON() {
    let malformed = [
      "{}",
      "{\"values\": [1.0, 2.0]}",
      "{\"quality\": 0.9}",
      "{\"values\": \"not-an-array\", \"quality\": 0.9}",
      "{\"values\": [1.0], \"quality\": \"not-a-float\"}",
    ]
    let decoder = JSONDecoder()
    var exercised = 0
    for json in malformed {
      #expect(throws: (any Error).self) {
        _ = try decoder.decode(VoicePrintVector.self, from: Data(json.utf8))
      }
      exercised += 1
    }
    #expect(exercised == malformed.count, "not all malformed cases ran: \(exercised)")
  }
}
