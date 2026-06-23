@preconcurrency import AVFoundation
import FluidAudio
import Foundation

// why: the engine talks to the project-owned protocol, not to FluidAudio types
// directly, so tests can substitute a fake without importing FluidAudio. Same
// adapter discipline as WhisperKitTranscriberAdapter / WhisperLiveTranscribing.
protocol ParakeetLiveStreaming: Sendable {
  /// Load the staged Parakeet EOU CoreML bundle from a manually-staged folder.
  /// MUST NOT touch the network — FluidAudio's auto-download path is intentionally not used,
  /// see ADR-0012 (supply-chain pinning is enforced by ParakeetModelInstaller, not here).
  func loadModels(from folderURL: URL) async throws
  func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async
  func setEouCallback(_ callback: @escaping @Sendable (String) -> Void) async
  /// Append 16 kHz mono Float32 samples; the adapter resamples internally if needed.
  func appendSamples(_ samples: [Float], sampleRate: Double) async throws
  func processBufferedAudio() async throws
  func reset() async throws
  func cleanup() async
}

// why: FluidAudio's StreamingEouAsrManager is itself an actor; this adapter is the bridge that
// (a) keeps our protocol AVAudioPCMBuffer-free (Sendable-safe across actor hops in Swift 6) and
// (b) reconstructs a minimal AVAudioPCMBuffer inside this actor to feed FluidAudio, which insists
// on the AVFoundation type at its public boundary.
actor SystemParakeetStreamingAdapter: ParakeetLiveStreaming {
  private let manager: StreamingEouAsrManager

  init(chunkSize: StreamingChunkSize = .ms160, eouDebounceMs: Int = 1280) {
    self.manager = StreamingEouAsrManager(
      chunkSize: chunkSize,
      eouDebounceMs: eouDebounceMs
    )
  }

  func loadModels(from folderURL: URL) async throws {
    try await manager.loadModels(from: folderURL)
  }

  func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async {
    await manager.setPartialCallback(callback)
  }

  func setEouCallback(_ callback: @escaping @Sendable (String) -> Void) async {
    await manager.setEouCallback(callback)
  }

  func appendSamples(_ samples: [Float], sampleRate: Double) async throws {
    guard !samples.isEmpty else { return }
    let buffer = try Self.makeBuffer(samples: samples, sampleRate: sampleRate)
    try await manager.appendAudio(buffer)
  }

  func processBufferedAudio() async throws {
    try await manager.processBufferedAudio()
  }

  func reset() async throws {
    // why: FluidAudio's StreamingEouAsrManager.reset() is `async` but NOT throwing;
    // the protocol keeps `throws` so a fake conformance may surface a failure, but the
    // real bridge has nothing to throw. `try` here would be a warnings-as-errors build
    // failure ("no calls to throwing functions occur within 'try'").
    await manager.reset()
  }

  func cleanup() async {
    await manager.cleanup()
  }

  private static func makeBuffer(samples: [Float], sampleRate: Double) throws -> AVAudioPCMBuffer {
    guard sampleRate > 0,
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
      ),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
      )
    else {
      throw ParakeetStreamingAdapterError.invalidAudioFormat
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    guard let channel = buffer.floatChannelData?[0] else {
      throw ParakeetStreamingAdapterError.invalidAudioFormat
    }
    samples.withUnsafeBufferPointer { src in
      // why: floatChannelData is contiguous Float for a non-interleaved mono format,
      // so a single memcpy is correct and cheaper than a loop. Source samples are an
      // Array<Float> already in 16 kHz mono per the engine's pipeline.
      channel.update(from: src.baseAddress!, count: samples.count)
    }
    return buffer
  }
}

enum ParakeetStreamingAdapterError: Error, Equatable {
  case invalidAudioFormat
}
