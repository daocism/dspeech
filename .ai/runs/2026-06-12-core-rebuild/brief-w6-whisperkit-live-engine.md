# W6 — WhisperKitLiveTranscriptionEngine + engine selection wiring

Read brief-common.md, then docs/adr/0011, then these landed pieces FIRST:
`Dspeech/Core/Audio/LiveAudioCaptureConduit.swift` (capture you MUST reuse),
`Dspeech/Core/ASR/WhisperKitModelInstaller.swift` (model location/state),
`Dspeech/Core/Settings/RecognitionSettings.swift` (engineChoice),
`Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift` (the behavioral template),
`Dspeech/Core/ASR/SpeechActivitySegmenter.swift` (EnergySilenceSegmenter).

## Files you own

- `Dspeech/Core/ASR/WhisperKitLiveTranscriptionEngine.swift` (new)
- `Dspeech/Core/ASR/WhisperKitTranscriberAdapter.swift` (new — the ONLY file that
  `import WhisperKit`)
- `Dspeech/App/ContentView.swift` (engine selection wiring ONLY — find where
  AppleSpeechLiveTranscriptionEngine is constructed; replace with a factory honoring
  RecognitionSettings.engineChoice + installer state)
- `DspeechTests/WhisperKitLiveTranscriptionEngineTests.swift` (new)
- pbxproj: engine fileRef `A00000000000000000000958`+buildFile `...0959`; adapter
  fileRef `...0962`+buildFile `...0963`; tests fileRef `...0964`+buildFile `...0965`
  (groups: ASR / ASR / DspeechTests; Sources phases `...0018`/`...0018`/`...0021`).
  PLUS the SPM package: mirror the FluidAudio pattern EXACTLY —
  XCRemoteSwiftPackageReference `A00000000000000000000960` (repositoryURL
  `https://github.com/argmaxinc/argmax-oss-swift.git`, requirement kind exactVersion
  1.0.0), XCSwiftPackageProductDependency `...0961` (productName WhisperKit),
  Frameworks buildFile `...0966` (`WhisperKit in Frameworks`), append to the app
  target's `packageProductDependencies` and the project's `packageReferences`.

## Engine design (binding)

```swift
// why: keeps WhisperKit out of unit tests — the engine depends on this seam,
// the adapter wraps the real pipeline.
protocol WhisperLiveTranscribing: Sendable {
  func loadModel(folderURL: URL) async throws
  func transcribe(samples: [Float], languageCode: String?) async throws
    -> [WhisperLiveSegment]   // text, startSeconds, endSeconds, avgLogProb
}

@MainActor
final class WhisperKitLiveTranscriptionEngine: LiveTranscriptionEngine {
  init(
    transcriber: any WhisperLiveTranscribing,
    installedModelFolderURL: @escaping @MainActor () -> URL?,
    localeProvider: @escaping @MainActor () -> String?,
    arbiter: AudioCaptureArbiter = .shared,
    audioSession: any LiveAudioSessionManaging = SystemLiveAudioSession()
  )
}
```

- `start()`: permission for microphone only (no SFSpeech permission needed; use the
  same authorizer seam pattern if needed for tests), resolve model folder — nil →
  `status = .failed("whisperkit-model-not-installed")`. Load model via transcriber
  (off-MainActor await), then `LiveAudioCaptureConduit.start(...)` exactly like the
  Apple engine (config-change → keep capturing, no task to recycle — emit
  `.taskRestart` only if you reset the rolling window; conduit failure →
  fail with slug after committing pending text).
- Streaming loop: consume conduit buffers; convert/accumulate into a 16kHz mono
  Float rolling window. Resample with AVAudioConverter (verify
  `AudioProcessor.resampleAudio` in the WhisperKit package source under
  Dspeech/Tools/ReplayKit/.build/checkouts/argmax-oss-swift — you may reimplement
  minimal AVAudioConverter resampling in the adapter instead; choose ONE, verify
  the API, no from-memory calls).
- Decode cadence: a repeating decode task — when ≥ `minNewAudioSeconds` (1.0) of
  NEW audio accumulated since last decode AND no decode in flight: decode the
  CURRENT window (from window start), emit `.partial(fullWindowText)`.
- Finalize when EnergySilenceSegmenter-style trailing silence ≥ 1.0s at the window
  end OR window length ≥ 28s: final decode of the window → emit `.segment` with
  trimmed text, confidence = mean(exp(avgLogProb)) clamped 0...1, sourceLanguageCode
  from locale, `source: .liveATC`; then advance the window start past the finalized
  audio and emit nothing for empty text. The TransmissionAssembler glues fragments
  downstream — your unit is the utterance window, exactly like Apple's task finals.
- `stop()`: cancel decode loop, conduit.stop(), do NOT emit a final decode (the VM
  commits the pending partial via the existing Stop path), status transitions
  matching the Apple engine (.stopped / failed slug on deactivation failure).
- Status lifecycle mirrors Apple engine: idle → requestingPermission → listening →
  stopped/failed. Emit `.status` through an identical multi-subscriber
  AsyncStream events() implementation.
- Privacy: assert/ensure the adapter only ever loads from the LOCAL installed
  folder (`WhisperKitConfig(modelFolder:..., download: false)`) — never a network
  download from the engine path.
- Decode runs off-MainActor (the transcriber protocol is Sendable; engine hops).

## ContentView wiring

Where the live engine is constructed: build per engineChoice —
`.apple` → existing construction unchanged; `.whisperKit` → if
`WhisperKitModelInstaller` state is installed, WhisperKit engine; else fall back to
Apple AND surface the existing Settings hint state (no silent fallback: log +
reuse/extend the inline hint the W7 picker added). Keep injection patterns
(@Observable, environment) consistent with the file's current style.

## Tests (fake transcriber, no model, no network)

- start without model → failed("whisperkit-model-not-installed").
- scripted samples: partial cadence (partials grow), silence-gap finalize emits
  `.segment` and advances window (next partial does NOT contain finalized text).
- stop mid-partial: no final decode, conduit released (fake arbiter assertions like
  the Apple lifecycle tests).
- conduit-failure path: pending partial committed as
  `.segment(isInterimRestartCommit: true)` then failed status.
- confidence mapping exp(avgLogProb) clamp.

Full build+test green, zero warnings, ReplayKit `swift build` still green, commit.
