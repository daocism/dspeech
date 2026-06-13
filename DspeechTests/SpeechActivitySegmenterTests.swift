import Foundation
import Testing

@testable import Dspeech

struct SpeechActivitySegmenterTests {
  private static let sampleRate = 16000.0

  private func makeSegmenter() -> EnergySilenceSegmenter {
    EnergySilenceSegmenter(
      minSpeechSeconds: 0.25,
      minSilenceSeconds: 0.40,
      maxWindowSeconds: 1.0
    )
  }

  private func block(seconds: Double, amplitude: Float) -> [Float] {
    let count = Int(seconds * Self.sampleRate)
    return [Float](repeating: amplitude, count: count)
  }

  @Test func cutsAfterTrailingSilenceFollowingSpeech() {
    let segmenter = makeSegmenter()
    #expect(
      segmenter.update(block: block(seconds: 0.3, amplitude: 0.5), sampleRate: Self.sampleRate)
        == .accumulate)
    #expect(
      segmenter.update(block: block(seconds: 0.5, amplitude: 0.0), sampleRate: Self.sampleRate)
        == .cutAfterSilence)
  }

  @Test func silenceBeforeSpeechDoesNotCutUntilMaxWindow() {
    // why: a long lead-in of room tone must not trigger a spurious empty cut.
    let segmenter = makeSegmenter()
    #expect(
      segmenter.update(block: block(seconds: 0.5, amplitude: 0.0), sampleRate: Self.sampleRate)
        == .accumulate)
    #expect(
      segmenter.update(block: block(seconds: 0.6, amplitude: 0.0), sampleRate: Self.sampleRate)
        == .cutAtMaxWindow)
  }

  @Test func continuousSpeechCutsAtMaxWindow() {
    let segmenter = makeSegmenter()
    #expect(
      segmenter.update(block: block(seconds: 1.1, amplitude: 0.5), sampleRate: Self.sampleRate)
        == .cutAtMaxWindow)
  }

  @Test func resetClearsAccumulators() {
    let segmenter = makeSegmenter()
    _ = segmenter.update(block: block(seconds: 0.3, amplitude: 0.5), sampleRate: Self.sampleRate)
    segmenter.reset()
    // After reset, a short silence block must accumulate (no carried-over speech state).
    #expect(
      segmenter.update(block: block(seconds: 0.5, amplitude: 0.0), sampleRate: Self.sampleRate)
        == .accumulate)
  }

  @Test func emptyBlockAccumulates() {
    let segmenter = makeSegmenter()
    #expect(segmenter.update(block: [], sampleRate: Self.sampleRate) == .accumulate)
  }

  @Test func zeroSampleRateAccumulates() {
    let segmenter = makeSegmenter()
    #expect(segmenter.update(block: [0.5, 0.5, 0.5], sampleRate: 0) == .accumulate)
  }

  @Test func quietBlockBelowThresholdCountsAsSilence() {
    let segmenter = makeSegmenter()
    _ = segmenter.update(block: block(seconds: 0.3, amplitude: 0.5), sampleRate: Self.sampleRate)
    // amplitude 0.005 RMS < 0.0125 threshold -> treated as silence -> cut after enough silence.
    #expect(
      segmenter.update(block: block(seconds: 0.5, amplitude: 0.005), sampleRate: Self.sampleRate)
        == .cutAfterSilence)
  }

  @Test func cutsAfterSilenceEvenWhenSilenceCarriesRealisticDeviceNoiseFloor() {
    // why: on a real iPhone the gap between transmissions is NOT digital zero — the mic noise
    // floor / AGC sits well above a naive absolute threshold. A fixed-threshold detector reads
    // that ambient as speech and NEVER cuts -> the whole flight is one un-segmented window
    // (2026-06-13 device report: "works like a dictaphone, new text replaces old"). Silence must
    // be detected RELATIVE to the floating noise floor, never against an absolute constant.
    let segmenter = makeSegmenter()
    _ = segmenter.update(block: block(seconds: 0.3, amplitude: 0.4), sampleRate: Self.sampleRate)
    #expect(
      segmenter.update(block: block(seconds: 0.5, amplitude: 0.03), sampleRate: Self.sampleRate)
        == .cutAfterSilence,
      "real silence gap (ambient RMS 0.03) must still close the utterance window")
  }

  @Test(arguments: [Float(0.0), 0.008, 0.02, 0.035, 0.05])
  func cutsAfterSilenceAcrossRealisticNoiseFloors(_ floor: Float) {
    // why: measured across the real range of device noise floors, not one guessed point. Speech
    // (loud) over a floor reads as speech; the floor itself reads as silence; the window closes.
    let segmenter = makeSegmenter()
    _ = segmenter.update(
      block: block(seconds: 0.3, amplitude: 0.4 + floor), sampleRate: Self.sampleRate)
    #expect(
      segmenter.update(block: block(seconds: 0.5, amplitude: floor), sampleRate: Self.sampleRate)
        == .cutAfterSilence,
      "noise floor \(floor): a trailing gap at the ambient level must close the window")
  }

  @Test func cutAfterSilenceTakesPrecedenceOverMaxWindow() {
    // why: when a block both completes an utterance (speech + trailing silence) and
    // exceeds maxWindow, the silence edge is the meaningful cut and is checked first.
    let segmenter = makeSegmenter()
    _ = segmenter.update(block: block(seconds: 0.3, amplitude: 0.5), sampleRate: Self.sampleRate)
    // 0.8s silence: trailingSilence >= 0.40 AND window 0.3 + 0.8 = 1.1 >= 1.0.
    #expect(
      segmenter.update(block: block(seconds: 0.8, amplitude: 0.0), sampleRate: Self.sampleRate)
        == .cutAfterSilence)
  }

  @Test("should preserve generated speech and silence cut invariants")
  func shouldPreserveGeneratedSpeechAndSilenceCutInvariants() {
    let generatedCaseCount = 300
    let minSpeech = 0.25
    let minSilence = 0.20
    let maxWindow = 0.75
    let maxBlockSeconds = 0.05
    var random = DeterministicSegmenterRandom(seed: 0xD5_06_11_05)

    for _ in 0..<generatedCaseCount {
      let segmenter = EnergySilenceSegmenter(
        minSpeechSeconds: minSpeech,
        minSilenceSeconds: minSilence,
        maxWindowSeconds: maxWindow
      )
      var speechSeconds = 0.0
      var trailingSilenceSeconds = 0.0
      var windowSeconds = 0.0
      var cutSeen = false

      for _ in 0..<64 {
        let seconds = Double(random.int(in: 1...5)) / 100
        let speech = random.bool()
        let samples = block(seconds: seconds, amplitude: speech ? 0.35 : 0.0)
        let blockSeconds = Double(samples.count) / Self.sampleRate
        let decision = segmenter.update(block: samples, sampleRate: Self.sampleRate)

        windowSeconds += blockSeconds
        if speech {
          speechSeconds += blockSeconds
          trailingSilenceSeconds = 0
        } else {
          trailingSilenceSeconds += blockSeconds
        }

        switch decision {
        case .accumulate:
          #expect(windowSeconds < maxWindow)
        case .cutAfterSilence:
          #expect(speechSeconds >= minSpeech)
          #expect(trailingSilenceSeconds >= minSilence)
          cutSeen = true
        case .cutAtMaxWindow:
          #expect(windowSeconds >= maxWindow)
          #expect(windowSeconds <= maxWindow + maxBlockSeconds)
          cutSeen = true
        }

        if cutSeen {
          segmenter.reset()
          #expect(
            segmenter.update(
              block: block(seconds: 0.05, amplitude: 0.0),
              sampleRate: Self.sampleRate
            ) == .accumulate)
          break
        }
      }

      #expect(cutSeen)
    }

    print("PBT_CASE_COUNT speech-activity-segmenter=300")
    #expect(generatedCaseCount == 300)
  }

  private struct DeterministicSegmenterRandom {
    private var state: UInt64

    init(seed: UInt64) {
      self.state = seed
    }

    mutating func next() -> UInt64 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return state
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
      let span = UInt64(range.upperBound - range.lowerBound + 1)
      return range.lowerBound + Int(next() % span)
    }

    mutating func bool() -> Bool {
      next().isMultiple(of: 2)
    }
  }
}
