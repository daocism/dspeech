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
}
