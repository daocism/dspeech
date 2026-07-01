import Foundation
import Testing

@testable import Dspeech

// why: SystemParakeetStreamingAdapter bridges to FluidAudio's real StreamingEouAsrManager, whose
// init/reset/cleanup are I/O-free (all model refs stay nil until loadModels). That lets these tests
// drive the adapter's own method bodies against the REAL manager without staged CoreML models. The
// branches that DO need the runtime — loadModels(from:), the makeBuffer success path feeding
// manager.appendAudio, and processBufferedAudio — belong to the on-device eval lane. The protocol
// substitution is already covered by ParakeetLiveTranscriptionEngineTests' FakeParakeetLiveStreaming;
// this suite targets the concrete adapter instead.
struct ParakeetStreamingAdapterTests {
  @Test func shouldReturnEarlyWithoutThrowingWhenAppendSamplesReceivesEmptySamples() async throws {
    let adapter = SystemParakeetStreamingAdapter()
    try await adapter.appendSamples([], sampleRate: 16_000)
  }

  // why: makeBuffer's `sampleRate > 0` guard is the only makeBuffer failure branch reachable
  // deterministically (positive rates always yield a valid mono Float32 format + channel data). It
  // throws BEFORE touching the manager, so no models are needed.
  @Test(arguments: [0.0, -1.0, -16_000.0] as [Double])
  func shouldThrowInvalidAudioFormatWhenSampleRateIsNonPositive(sampleRate: Double) async {
    let adapter = SystemParakeetStreamingAdapter()
    await #expect(throws: ParakeetStreamingAdapterError.invalidAudioFormat) {
      try await adapter.appendSamples([0.1, 0.2, 0.3], sampleRate: sampleRate)
    }
  }

  // why: proves the adapter's callback + reset + cleanup forwarding runs end-to-end against the real
  // FluidAudio manager without any loaded models — the model-free half of the lifecycle the engine
  // relies on. All four hops must complete without throwing.
  @Test func shouldForwardModelFreeLifecycleWithoutThrowing() async throws {
    let adapter = SystemParakeetStreamingAdapter()
    await adapter.setPartialCallback { _ in }
    await adapter.setEouCallback { _ in }
    try await adapter.appendSamples([], sampleRate: 16_000)
    await adapter.reset()
    await adapter.cleanup()
  }

  @Test func invalidAudioFormatErrorShouldBeEquatable() {
    #expect(ParakeetStreamingAdapterError.invalidAudioFormat == .invalidAudioFormat)
  }
}
