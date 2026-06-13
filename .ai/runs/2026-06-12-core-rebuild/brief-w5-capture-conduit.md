# W5 — Extract LiveAudioCaptureConduit; Apple engine composes it

Read brief-common.md first. Same rules.

## Files you own

- `Dspeech/Core/Audio/LiveAudioCaptureConduit.swift` (new)
- `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift` (refactor onto the conduit)
- `Dspeech/Core/ASR/AppleSpeechEngineSupport.swift` (move/share what belongs to capture)
- `DspeechTests/LiveAudioCaptureConduitTests.swift` (new)
- pbxproj: conduit fileRef `A00000000000000000000950` + buildFile `...0951` (app target
  Sources `...0018`, group `Audio` `...0008`); tests fileRef `...0952` + buildFile
  `...0953` (test target Sources `...0021`, group DspeechTests `...0010`).

## Goal

The WhisperKit live engine (next work package) needs the EXACT same audio capture
guarantees the Apple engine spent weeks earning: arbiter acquisition, session
configure/activate, AVAudioEngine + tap with `format: nil` + `@Sendable` deep-copy
(the realtime-thread crash class), invalid-input-format guard, configuration-change
observer, FIFO AsyncStream of captured buffers, clean teardown order, deactivation
with `.notifyOthersOnDeactivation`. Duplicating that code would fork the crash fixes.
Extract it ONCE as a conduit; the Apple engine becomes a consumer.

## Contract (binding)

```swift
struct LiveCapturedAudioBuffer: @unchecked Sendable {
  let buffer: AVAudioPCMBuffer
  let samples: [Float]
  let sampleRate: Double
}

@MainActor
final class LiveAudioCaptureConduit {
  init(
    arbiter: AudioCaptureArbiter = .shared,
    audioSession: any LiveAudioSessionManaging = SystemLiveAudioSession()
  )

  // why: begins session + engine + tap; returns the FIFO buffer stream. Throws
  // LiveEngineError / session errors. `onConfigurationChange` fires on
  // AVAudioEngineConfigurationChange AFTER the conduit rebuilt engine+tap
  // successfully (consumer decides what to do with its recognition task), or the
  // conduit calls `onFailure(slug)` when the rebuild fails (consumer fails the session).
  func start(
    onConfigurationChange: @escaping @MainActor () -> Void,
    onFailure: @escaping @MainActor (String) -> Void
  ) throws -> AsyncStream<LiveCapturedAudioBuffer>

  var isEngineRunning: Bool { get }
  // why: mirrors current cleanup(): stop engine, remove tap, finish stream,
  // release arbiter, deactivate session; returns deactivation failure slug if any.
  func stop() -> LiveEngineCleanupResult
}
```

Move `dspeechDeepCopy`, `monoFloatSamples`, the tap-install block (verbatim with its
`// why:` comments — they are load-bearing institutional knowledge), the
invalid-format guard, the configuration-change observer and the capture
AsyncStream plumbing INTO the conduit. `AppleSpeechLiveTranscriptionEngine` keeps:
permissions, recognizer/task lifecycle, router/gate wiring, replay tail, restart
taxonomy, interim commits, events — and consumes the conduit for all audio.
`CapturedAudioBuffer` in AppleSpeechEngineSupport.swift is replaced by
`LiveCapturedAudioBuffer` (delete the old type; update W2's test seams if they
reference it).

## Non-negotiable invariants (these are pinned by existing tests — keep them green)

- Arbiter acquire BEFORE session begin; release + deactivate ONLY from stop(); a
  failed start releases what it acquired.
- Tap closure: `@Sendable`, captures only the continuation, deep-copies, never
  touches @MainActor state. `format: nil` stays.
- The engine's externally observable behavior (status transitions, events, restart
  semantics, interim commits) must be UNCHANGED — the full
  AppleSpeechLiveTranscriptionEngineLifecycleTests suite and
  OnDeviceSpeechRecognitionTests.engineAudioPathInstallsTapWithoutCrashing must pass
  untouched (you may update only construction plumbing in tests if init signatures
  change — do NOT weaken assertions).

## Conduit tests (new file)

Arbiter-busy start fails with capture-session-busy; stop releases arbiter and
deactivates; failed session-activate path releases arbiter; stream finishes on stop
(no buffer delivered after); double-start guarded. Use the existing fake
arbiter/session test doubles from the lifecycle tests file as the pattern.

Verify: full build test green, zero warnings. Commit.
