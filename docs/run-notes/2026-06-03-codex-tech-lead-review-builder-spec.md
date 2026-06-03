# 2026-06-03 Codex tech-lead review and Claude-builder spec

Mode: tech-lead review plus scoped Codex implementation passes. This file now tracks both the original findings and the fixes already landed by Codex.
Reviewer: Codex.
Repository state: `fix/review-hardening-2026-06-03`; this note records Codex fixes through the voice-enrollment recorder lifecycle pass.

## Verification evidence

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version` -> Xcode 26.4, build 17E192.
- XcodeBuildMCP simulator test failed before build because active developer directory is CommandLineTools and MCP could not find `simctl`.
- Shell fallback with explicit `DEVELOPER_DIR` succeeded:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechTests build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_11-49-35-+0200.xcresult`
- Full simulator build and test also succeeded:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' CODE_SIGNING_ALLOWED=NO build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_11-54-43-+0200.xcresult`
  - UI suite ran 11 tests and passed, but `testStartButtonDoesNotCrashAppWithPermissionsPreGranted` is not a true start proof. The log waited for `stop-button`, did not find it, then passed because `start-button` still existed.
- Banned-marker grep over app/tests/docs/scripts returned no stale-work or panic markers.
- Xcode project membership check found all `Dspeech/`, `DspeechTests/`, and `DspeechUITests/` Swift files referenced by `Dspeech.xcodeproj`; only standalone `Dspeech/Tools/` packages/probes are outside the app/test targets.
- `swift format lint --strict --recursive Dspeech DspeechTests DspeechUITests` passed.
- `scripts/release/check-release-ready.sh` failed only on missing captured App Store screenshots under `tmp/app-store-screenshots/`; do not generate or publish App Store assets without explicit sign-off.
- Privacy manifest inspected with `plutil -p`: declares UserDefaults required-reason API `CA92.1`, no collected data, no tracking, and is bundled in app resources.
- Build settings inspected with explicit `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`: app/test targets resolve to Swift 6, `SWIFT_STRICT_CONCURRENCY=complete`, and iOS deployment target 26.0.
- Release simulator build succeeded with explicit `DEVELOPER_DIR`:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -configuration Release -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' -derivedDataPath tmp/codex-review-derived CODE_SIGNING_ALLOWED=NO build`
  - result: `** BUILD SUCCEEDED **`
  - binary scan found no `--dspeech-sfspeech-probe` / `Dspeech Speech Probe` marker strings in `tmp/codex-review-derived/Build/Products/Release-iphonesimulator/Dspeech.app/Dspeech`.
  - Release output map still lists `Dspeech/App/SimulatorSpeechProbe.swift` with `SimulatorSpeechProbe.o` and `SimulatorSpeechProbe.bc`; the probe source is compiled before dead stripping.
  - the same binary scan did find unrelated FluidAudio ASR/TTS/resource-download symbols and model-source strings including `Qwen3ASR`, `Parakeet`, `CohereTranscribe`, `KokoroAne`, `PocketTts`, `StyleTTS2`, `Supertonic3`, `DownloadUtils`, `FluidInference/...`, and `https://huggingface.co`.
  - `find tmp/codex-review-derived/SourcePackages/checkouts/FluidAudio -maxdepth 3 -type f -name '*xcprivacy'` found no FluidAudio privacy manifest file.
  - Release build settings were not the issue here: explicit `-showBuildSettings` reported `ENABLE_TESTABILITY = NO`, `GENERATE_PROFILING_CODE = NO`, `SWIFT_COMPILATION_MODE = wholemodule`, and `VALIDATE_PRODUCT = YES`.

## 2026-06-03 Codex implementation progress

Scope completed in this pass:
- `Dspeech/Core/ASR/CallsignDictationService.swift` now has a deterministic MainActor lifecycle with `.starting`, session IDs, injected authorization/recognizer/audio-capture seams, recognition request creation before capture start, deep-copied tap buffers routed through a serial `AsyncStream`, and stale callback/buffer rejection after stop/restart.
- `AppleCallsignSpeechRecognizer` and `AVAudioEngineCallsignAudioCapture` no longer use `@unchecked Sendable`; the only remaining unchecked wrapper is a deep-copied `CallsignCapturedBuffer` with a local invariant and lifecycle tests.
- `DspeechTests/CallsignDictationServiceTests.swift` is added to the `DspeechTests` target and covers authorization denial, microphone denial, nil/unavailable recognizer, missing on-device model, capture-start failure cleanup, recognition-before-capture ordering, partial updates, benign final, hard early recognition error, stop cleanup, duplicate start during suspended authorization, stop during startup, late buffer after stop, and stale update after stop.
- `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift` now has startup generation ownership, injected speech authorization, duplicate-start idempotence while permission requests are suspended, and Stop-during-startup guards after speech auth, microphone auth, and audio-start boundaries.
- `Dspeech/App/LiveTranscriptionViewModel.swift`, `Dspeech/App/CaptureCoordinator.swift`, and `Dspeech/App/ContentView.swift` now expose Stop during `.requestingPermission` / start-in-flight states instead of treating only `.listening` as stoppable.
- `DspeechTests/AppleSpeechLiveTranscriptionEngineLifecycleTests.swift`, `DspeechTests/LiveTranscriptionViewModelTests.swift`, and `DspeechTests/CaptureCoordinatorTests.swift` cover duplicate Start, Stop during speech auth, Stop during mic auth, coordinator toggle during startup, background stop during startup, and route loss during startup.
- `DspeechUITests/DspeechUITests.swift` replaces the weak Start smoke with `testStartTransitionsToListeningOrVisibleFailure`, which fails if Start silently returns to idle with only `start-button` visible and no typed `error-banner`.
- `Dspeech/App/AudioSourceController.swift` now treats saved-input reapply like manual selection: OS rejection becomes visible through `selectionError`, and Settings falls back to the actual current input instead of claiming the rejected persisted UID is active.
- `DspeechTests/UtteranceWindowRouterTests.swift` and `DspeechTests/SerialBufferRouterTests.swift` no longer contain stale implementation-phase comments claiming production seams are missing or RED.
- `Dspeech/Core/VoiceFilter/SpeakerModelPackInstaller.swift` now exposes a real uninstall API. `voicefilter-modelpack-delete` actions call it before transitioning to `.absent`, and deletion errors become visible `.disk` failures with delete-specific copy.
- `Dspeech/Core/Audio/InputLevelMeter.swift` now emits typed meter events (`level` or `failed`) instead of silently finishing on invalid input format or `AVAudioEngine.start()` failure.
- `Dspeech/App/AudioSourceController.swift` tracks `inputLevelError`, clears it on fresh meter start, stops the meter after failure, and resets the displayed level to zero only alongside a visible error reason.
- `Dspeech/App/ContentView.swift` surfaces meter failure in Settings with accessibility id `audio-meter-error`.
- `DspeechTests/AudioSourceControllerTests.swift` covers normal meter levels, stop cleanup, and visible failure handling; `DspeechTests/OnDeviceSpeechRecognitionTests.swift` now consumes typed meter events.
- `DspeechTests/LiveTranscriptionViewModelTests.swift` hardens `retranslateAllRetranslatesExistingSegments()` so it waits for the new translated gloss, not just an internal translation call count.
- `Dspeech/Core/Translation/TranslationServiceProtocol.swift` now exposes typed `TranslationFailure` state that preserves missing-pack, unsupported-language, unsupported-pair, cancellation, preparation, and engine failures without collapsing them to a boolean.
- `Dspeech/App/LiveTranscriptionViewModel.swift` records translation service failures and clears them only on a successful translation or explicit translation reset.
- `Dspeech/App/ContentView.swift` maps `.translationTask` preparation failures through `TranslationFailure.preparation(...)` instead of swallowing them, guards preparation errors with a config token, and Settings surfaces the reason with accessibility id `translation-failure`.
- `Dspeech/App/RecognitionFailureText.swift`, `DspeechTests/LiveTranscriptionViewModelTests.swift`, `DspeechTests/TranslationServiceTests.swift`, and `DspeechTests/RecognitionFailureTextTests.swift` now cover user-safe translation failure copy, service failure mapping, preparation failure mapping, stale preparation error rejection, and recovery after success.
- `DspeechTests/UtteranceWindowRouterTests.swift` no longer contains the remaining stale `RED until EnergySilenceSegmenter exists` comment now that the production segmenter and tests are green.
- `Dspeech/Core/VoiceFilter/VoiceFilterStorage.swift` now loads voice-filter persistence through a typed `VoiceFilterStorageSnapshot` with explicit `VoiceFilterStorageIssue` values for corrupt profiles, callsign, gate config, and enabled flag.
- `Dspeech/Core/VoiceFilter/VoiceFilterPipeline.swift` now initializes from one storage snapshot, exposes pending storage issues, and can clear only the corrupt persisted keys without rewriting healthy settings.
- `Dspeech/Core/VoiceFilter/ModelPackState.swift` now maps corrupt or unknown persisted model-pack state to `.failed(.corruptState)` with non-retryable user-safe copy instead of `.absent`.
- `Dspeech/App/ContentView.swift` now surfaces corrupt local voice-filter settings with `voicefilter-storage-corrupt` plus `voicefilter-storage-recovery`, and corrupt model-pack state uses the existing non-retryable continue-without path.
- `DspeechTests/VoiceFilterTests.swift` and `DspeechUITests/DspeechUITests.swift` now cover corrupt storage snapshots, selective corrupt-key clearing, pipeline issue propagation/reset, corrupt model-pack state, and UI recovery visibility.
- `Dspeech/Core/ASR/VoiceEnrollmentRecorder.swift` now has injectable microphone authorization and audio-capture seams, a `.starting` state, session UUID ownership, serial `AsyncStream` ingestion, deep-copied tap buffers, and an async stop contract that drains accepted buffers before returning while ignoring late or stale buffers.
- `Dspeech/App/ContentView.swift` now awaits recorder `stop()` before enrolling a voice sample, so the UI sends deterministic samples into `VoiceFilterPipeline`.
- `DspeechTests/VoiceEnrollmentRecorderTests.swift` is added to the `DspeechTests` target and covers start success, microphone denial, invalid input format, engine start failure, duplicate start idempotence, stop with samples, stop with no samples, late buffer rejection, stale prior-session buffer rejection, and restart clearing old samples.

Verification for this pass:
- XcodeBuildMCP `test_sim` still failed before build because `xcrun` could not find `simctl` under the active CommandLineTools developer directory.
- Narrow callsign suite passed:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechTests/CallsignDictationServiceTests build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_12-39-52-+0200.xcresult`
- Unit-only suite passed:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechTests build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_12-41-13-+0200.xcresult`
- `swift format lint --strict --recursive Dspeech DspeechTests DspeechUITests` passed.
- Banned-marker grep over app/tests/docs/scripts returned empty.
- `git diff --check` passed.
- Narrow startup lifecycle/ViewModel/Coordinator suite passed after fixing async waits:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechTests/AppleSpeechLiveTranscriptionEngineLifecycleTests -only-testing:DspeechTests/LiveTranscriptionViewModelTests -only-testing:DspeechTests/CaptureCoordinatorTests build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_12-53-54-+0200.xcresult`
- Strengthened Start UI test first failed before the permission-alert handler was improved, proving the old smoke test was weak. After the handler fix it passed:
  - command: `swift format lint --strict --recursive Dspeech DspeechTests DspeechUITests && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechUITests/DspeechUITests/testStartTransitionsToListeningOrVisibleFailure build test`
  - passing xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_12-58-52-+0200.xcresult`
- Full simulator build and test passed after the final async-race fix:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_13-04-13-+0200.xcresult`
- Targeted audio-source controller suite passed after the persisted-input rejection fix:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechTests/AudioSourceControllerTests build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_13-09-28-+0200.xcresult`
- Unit-only suite passed after the F5/F29 patch:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechTests build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_13-10-42-+0200.xcresult`
- Focused model-pack installer/failure suite passed after the uninstall fix:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechTests/SpeakerModelPackInstallerTests -only-testing:DspeechTests/ModelPackDownloadFailureTests build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_13-15-02-+0200.xcresult`
- Unit-only suite passed after the F10 patch:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechTests build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_13-16-17-+0200.xcresult`
- Full simulator build and test passed after all current Codex patches:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_13-17-12-+0200.xcresult`
  - UI suite ran 11 tests with 0 failures. The strengthened Start test still required either `stop-button` or visible `error-banner`; it passed by observing the typed failure path in this simulator environment.
- Focused meter suite passed after the F4 typed-event patch:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechTests/AudioSourceControllerTests -only-testing:DspeechTests/OnDeviceSpeechRecognitionTests/inputLevelMeterInstallsTapWithoutCrashing build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_13-22-33-+0200.xcresult`
- Unit-only suite passed after the F4 patch:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechTests build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_13-24-18-+0200.xcresult`
- First full simulator run after the F4 patch exposed a weak async translation test:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO build test`
  - result: `** TEST FAILED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_13-25-00-+0200.xcresult`
  - failure: `LiveTranscriptionViewModelTests.retranslateAllRetranslatesExistingSegments()` observed the internal call count before the async translated gloss was written.
- Focused translation regression passed after hardening that assertion:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechTests/LiveTranscriptionViewModelTests/retranslateAllRetranslatesExistingSegments build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_13-28-26-+0200.xcresult`
- Full simulator build and test passed after the F4 patch and translation-test hardening:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_13-29-03-+0200.xcresult`
  - UI suite ran 11 tests with 0 failures; unit suite passed with the existing synthesized-speech device capability test skipped on simulator.
- Final hygiene for this pass:
  - `swift format lint --strict --recursive Dspeech DspeechTests DspeechUITests` passed.
  - `git diff --check` passed.
  - banned-marker grep over app/tests/docs/scripts returned empty.
  - source-only stale implementation text grep over `Dspeech DspeechTests DspeechUITests` returned empty for old RED/missing-seam phrases.
- Final hygiene was repeated after the F4/spec/test-hardening update:
  - `swift format lint --strict --recursive Dspeech DspeechTests DspeechUITests` passed.
  - `git diff --check` passed.
  - banned-marker grep over app/tests/docs/scripts returned empty.
- Focused translation failure suite passed after the F3 patch:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechTests/LiveTranscriptionViewModelTests -only-testing:DspeechTests/TranslationServiceTests -only-testing:DspeechTests/TranslationFailureTextTests build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_13-48-22-+0200.xcresult`
- Unit-only suite passed after the F3 patch:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechTests build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_13-41-16-+0200.xcresult`
- Full simulator build and test passed after the F3 patch:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_13-49-02-+0200.xcresult`
  - UI suite ran 11 tests with 0 failures; the strengthened Start test again passed by observing the typed failure path in this simulator environment.
- Final hygiene was repeated after the F3/spec update:
  - `swift format lint --strict --recursive Dspeech DspeechTests DspeechUITests` passed.
  - `git diff --check` passed.
  - banned-marker grep over app/tests/docs/scripts returned empty.
- Focused corrupt-state unit suite passed after the F6 patch:
  - command: `swift format lint --strict --recursive Dspeech DspeechTests DspeechUITests && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechTests/VoiceFilterStorageTests -only-testing:DspeechTests/ModelPackStateStorageTests -only-testing:DspeechTests/VoiceFilterPipelineTests build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_13-58-25-+0200.xcresult`
- Focused corrupt-state UI suite passed after the F6 patch:
  - command: `swift format lint --strict --recursive Dspeech DspeechTests DspeechUITests && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechUITests/DspeechUITests/testCorruptVoiceFilterStorageShowsRecoveryBanner -only-testing:DspeechUITests/DspeechUITests/testCorruptModelPackStateShowsContinueWithoutPath build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_14-00-20-+0200.xcresult`
- Full simulator build and test passed after the F6 patch:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_14-01-22-+0200.xcresult`
  - UI suite ran 13 tests with 0 failures; unit suite passed with the existing synthesized-speech device capability test skipped on simulator.
- Final hygiene was repeated after the F6/spec update:
  - `swift format lint --strict --recursive Dspeech DspeechTests DspeechUITests` passed.
  - `git diff --check` passed.
  - banned-marker grep over app/tests/docs/scripts returned empty.
  - source-only stale implementation text grep over `Dspeech DspeechTests DspeechUITests` returned empty for old RED/missing-seam phrases.
- Focused recorder lifecycle suite passed after the F19 patch:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechTests/VoiceEnrollmentRecorderTests build test`
  - result: `** TEST SUCCEEDED **`
  - latest xcresult after Xcode target-membership cleanup: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_14-20-37-+0200.xcresult`
  - all ten recorder lifecycle cases ran.
- Unit-only suite passed after the F19 patch:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechTests build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_14-13-19-+0200.xcresult`
- Full simulator build and test passed after the F19 patch:
  - command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO build test`
  - result: `** TEST SUCCEEDED **`
  - xcresult: `/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.06.03_14-13-54-+0200.xcresult`
  - UI suite ran 13 tests with 0 failures; unit suite passed with the existing synthesized-speech device capability test skipped on simulator.
- Final hygiene was repeated after the F19/spec update:
  - `swift format lint --strict --recursive Dspeech DspeechTests DspeechUITests` passed.
  - `git diff --check` passed.
  - banned-marker grep over app/tests/docs/scripts returned empty.
  - source-only stale implementation text grep over `Dspeech DspeechTests DspeechUITests` returned empty for old RED/missing-seam phrases.
  - `VoiceEnrollmentRecorderTests.swift` target membership check found file reference, build file, group membership, and `DspeechTests` sources membership in `Dspeech.xcodeproj/project.pbxproj`.

Findings status after this pass:
- `F1`, `F2`, and `F12` are addressed for callsign dictation by code plus tests above.
- `F3` is addressed for translation failure visibility by typed failure state, Settings copy, `.translationTask` preparation mapping, config-token stale error rejection, and tests above.
- `F4` is addressed for meter start/format failures by typed meter events, visible Settings error state, and tests above.
- `F5` is addressed for persisted audio-input reapply by code plus tests above.
- `F6` is addressed for corrupt local voice/model state by typed persistence issues, visible recovery UI, non-retryable corrupt model-pack failure state, and tests above.
- `F19` is addressed for voice enrollment recorder lifecycle by injected seams, session-owned stream ingestion, async drain-on-stop semantics, late/stale buffer rejection, and direct recorder unit tests.
- `F9` and `F28` are addressed for the main Start lifecycle/UI contract by code plus tests above.
- `F10` is addressed for the product contract: delete now removes local model files before clearing state, and delete failure is visible.
- `F29` is addressed by removing stale implementation-phase comments from current green test seams.
- Broad product goal remains open. Other findings in this file still need builder work and review.

## Review findings

### F1 HIGH: Callsign dictation refactor has zero direct tests

Evidence:
- Changed file: `Dspeech/Core/ASR/CallsignDictationService.swift`, 157 insertions in dirty diff.
- `rg "CallsignDictationService|voicefilter-callsign-dictate|dictation" DspeechTests DspeechUITests` only matches generic Speech request usage in `OnDeviceSpeechRecognitionTests.swift`.

Risk:
- The refactor added authorization, recognizer, recognition-task, audio-capture seams, hard-error handling, on-device-model gating, and cleanup ordering. None of these contracts are pinned.
- A green `DspeechTests` run does not prove this changed component works. This repeats the F1 failure pattern: tests certify adjacent plumbing, not the touched capability.

Builder requirement:
- Add `DspeechTests/CallsignDictationServiceTests.swift`.
- Cover: speech auth denied, mic denied, nil recognizer, unavailable recognizer, on-device unsupported recognizer, capture-start failure, start success, partial update, benign 1110 final -> idle, hard error -> unavailable with error text, stop cleanup, duplicate start idempotence.
- Use injected fakes only. No real microphone, no real Speech framework in these unit tests.

### F2 HIGH: Callsign dictation hides actor/thread safety behind unchecked Sendable

Evidence:
- `Dspeech/Core/ASR/CallsignDictationService.swift:89-106` starts audio capture and forwards realtime tap buffers directly into `recognizer.append`.
- `Dspeech/Core/ASR/CallsignDictationService.swift:169-213` marks `AppleCallsignSpeechRecognizer` as `@unchecked Sendable`, stores mutable `request`, appends from the audio tap thread, and nils the request on MainActor cleanup.
- Apple AVAudio tap docs state the tap block may run on a non-main thread.

Risk:
- This is the same class of bug that previously crashed ASR tap callbacks: AI added `@unchecked Sendable` to satisfy Swift 6 without proving isolation.
- `request?.append(buffer)` and `request = nil` can race unless all access is serialized.

Builder requirement:
- Do not let the tap call the recognizer object directly.
- Mirror the proven engine pattern: deep-copy buffer in the tap, yield to a Sendable stream, consume on one actor/serial executor, append only while a generation/session token is current.
- Remove or sharply justify every `@unchecked Sendable` in this file. If any remains, document the invariant in the spec and pin it with a concurrency/lifecycle test.

### F3 MEDIUM: Translation failures still fail silently

Status after Codex implementation pass: addressed. Translation service and preparation failures now become typed `TranslationFailure` values, Settings renders a reason with `translation-failure`, stale preparation errors are token-guarded, and tests cover all service cases plus preparation mapping.

Evidence:
- `Dspeech/App/LiveTranscriptionViewModel.swift:141-151` only surfaces `.languagePackNotInstalled`; other `TranslationServiceError` values silently leave the segment un-glossed.
- `Dspeech/App/ContentView.swift:155-167` catches `.translationTask` prepare failures and does nothing.
- Existing run-note already lists this as backlog: `docs/run-notes/2026-06-02c-f1-asr-silent-failure-fix.md:112-116`.

Risk:
- User-visible translation failure is indistinguishable from "nothing happened". This is a direct sibling of the silent ASR failure pattern.

Builder requirement:
- Add an explicit translation failure state, not just a boolean.
- Distinguish missing pack, unsupported pair, engine failure, cancelled/user-dismissed prepare.
- Update Settings copy and accessibility identifier so the reason is visible.
- Add tests for all non-pack `TranslationServiceError` cases and `.translationTask` genuine failure handling.

### F4 MEDIUM: Input level meter start failure is still converted to silent zero

Status after Codex implementation pass: addressed. Meter start and invalid-format failures now emit typed failure events, Settings exposes `audio-meter-error`, and controller tests prove failure visibility plus cleanup.

Evidence:
- `Dspeech/Core/Audio/InputLevelMeter.swift:54-60` catches `engine.start()` failure, removes the tap, finishes the stream, and exposes no error to `AudioSourceController`.
- Existing run-note already lists this as backlog: `docs/run-notes/2026-06-02c-f1-asr-silent-failure-fix.md:117-118`.

Risk:
- The UI can show a dead 0-level meter when the real problem is audio session failure. That trains the user to misdiagnose hardware/input problems.

Builder requirement:
- Change `InputLevelMetering` to emit a typed event: level or failure.
- Surface a Settings error state with accessibility id.
- Add tests for start failure, invalid format, normal levels, and stop cleanup.

### F5 MEDIUM: Persisted audio-input reapply still swallows OS rejection

Status after Codex implementation pass: addressed. Persisted reapply now surfaces OS rejection, falls back to the current route input, and has rejected-input regression tests.

Evidence:
- `Dspeech/App/AudioSourceController.swift:69-74` uses `try? routing.setPreferredInput(uid:)`.
- `select(uid:)` has the correct do/catch behavior at `Dspeech/App/AudioSourceController.swift:76-90`.
- Tests cover happy-path persisted reapply only: `DspeechTests/AudioSourceControllerTests.swift:50-59`.

Risk:
- On launch, a saved but OS-rejected input can fail invisibly. The app then appears configured for a source it did not actually apply.

Builder requirement:
- Make `applyPersistedPreference()` follow the same contract as `select(uid:)`: attempt first, surface `selectionError`, and do not imply the saved source is active if the OS rejected it.
- Extend `FakeAudioSessionRouting` to throw deterministically.
- Add tests for persisted preference rejection and successful reapply.

### F6 MEDIUM: Corrupt local voice/model state is still collapsed into absent/default

Status after Codex implementation pass: addressed. Voice-filter storage now distinguishes absence from corrupt persisted values, Settings exposes a user-safe reset path for corrupt local voice-filter data, and corrupt model-pack state becomes `.failed(.corruptState)` instead of pretending the pack was never installed.

Evidence:
- `Dspeech/Core/VoiceFilter/VoiceFilterStorage.swift:29-59` decodes corrupt profile/callsign/config data into empty/default/nil.
- `Dspeech/Core/VoiceFilter/ModelPackState.swift:151-156` decodes corrupt model-pack state into `.absent`.
- Existing run-note already lists this as backlog: `docs/run-notes/2026-06-02c-f1-asr-silent-failure-fix.md:119-121`.

Risk:
- Corrupt persisted state looks like "never enrolled" or "never installed", not data loss or re-verification needed.

Builder requirement:
- Introduce typed load results for persisted voice-filter state where corruption is distinguishable from absence.
- Surface a user-safe recovery path for corrupt voice profiles/model-pack state.
- Add round-trip and corrupt-blob tests.

### F7 LOW: Device-only primary capability remains unproven by the current local run

Evidence:
- Simulator unit suite succeeded.
- `OnDeviceSpeechRecognitionTests/recognizesSynthesizedSpeechEndToEnd()` was skipped on simulator.
- `docs/run-notes/2026-06-02c-f1-asr-silent-failure-fix.md:124-130` lists missing device/integration lanes.

Risk:
- The project can still report green locally while the physical-device Speech path is not exercised.

Builder requirement:
- Keep simulator tests, but add a separate physical-device gate artifact before any "works on device" claim.
- Required device commands must be documented in `docs/DEVICE-INSTALL-WORKFLOW.md` or a dedicated runbook.
- Builder must record device UDID, command, result, and exact skipped tests.

### F8 MEDIUM: SwiftUI app shell is an AI monolith

Evidence:
- `Dspeech/App/ContentView.swift` is 1334 lines.
- `Dspeech/App/ContentView.swift:5-67` owns root dependency construction and app shell state.
- `Dspeech/App/ContentView.swift:437-658` defines `SettingsView`.
- `Dspeech/App/ContentView.swift:660-1030` defines the voice-filter settings section, callsign dictation button, model-pack UI, enrollment UI, and destructive model-pack actions.

Risk:
- This file now mixes composition root, screen layout, settings UX, voice-filter flows, model-pack install state, enrollment, dictation, formatting helpers, and destructive actions. That is exactly where Claude-authored code tends to accumulate cross-feature state leaks.
- Future review cannot isolate behavioral contracts because UI state, domain calls, and persistence-affecting actions are interleaved in one file.

Builder requirement:
- Split `ContentView.swift` by product surface and responsibility:
  - root composition/app shell;
  - transcript surface;
  - capture controls and route banner;
  - settings shell;
  - audio source settings;
  - translation settings;
  - voice-filter settings;
  - model-pack controls;
  - enrollment controls;
  - callsign dictation controls.
- Keep dependency construction in one small composition point or explicit factory.
- Do not move logic by copy-paste only. Extract testable view models or pure helpers where state transitions are currently embedded in button closures.
- After refactor, no hand-written SwiftUI file should exceed 400 lines without an ADR explaining why.

### F9 HIGH: The primary Start UI test can pass when listening never starts

Status after Codex implementation pass: addressed. The UI test now requires either visible listening state or a typed visible failure, and Start lifecycle unit tests cover duplicate and stopped startup paths.

Evidence:
- `DspeechUITests/DspeechUITests.swift:54-82` is named `testStartButtonDoesNotCrashAppWithPermissionsPreGranted`.
- `DspeechUITests/DspeechUITests.swift:72-80` waits for `stop-button`, then accepts `stopAppeared || startButton.exists`.
- Full UI test execution passed even though `stop-button` did not appear in the captured UI log.

Risk:
- This test is a crash smoke, not a Start happy-path test. It can certify a broken ASR start flow as green.
- This is a common AI-test anti-pattern: broad assertion text hides that no user-visible successful state is required.

Builder requirement:
- Rename this test to match its actual crash-smoke contract, or make it enforce the real Start contract.
- Add a separate happy-path UI test with injected fake engine or deterministic launch flag:
  - tap Start;
  - assert listening state (`stop-button`, live status, or stable accessibility id);
  - assert a visible typed failure if Start cannot proceed.
- The test must fail if the app silently returns to idle with only `start-button` visible and no explicit error.

### F10 MEDIUM: Model-pack delete UI does not delete the local model files

Status after Codex implementation pass: addressed. The delete actions now call `SpeakerModelPackInstaller.uninstall(_:)`, focused tests prove filesystem deletion, and delete errors map to visible disk failure state.

Evidence:
- `Dspeech/App/ContentView.swift:971-973` button text says `Удалить пакет`, but the action only does `transition(to: .absent)`.
- `Dspeech/App/ContentView.swift:1024-1026` repeats the same pattern for disabled content.
- `Dspeech/Core/VoiceFilter/SpeakerModelPackInstaller.swift:244-247` has a private `removeModelDirectory`, but it is only used by integrity retry at `Dspeech/Core/VoiceFilter/SpeakerModelPackInstaller.swift:97-99`.
- No test references `voicefilter-modelpack-delete` as a filesystem-removing action.

Risk:
- User-facing copy says destructive delete, but the model cache can remain on disk.
- The app can later rediscover files that the user believed were removed, and local storage/privacy behavior becomes untrustworthy.

Builder requirement:
- Decide the real product contract:
  - If the action means delete, add an uninstall API that removes the local model directory, updates persisted state, handles deletion errors visibly, and tests filesystem effects.
  - If the action only means disable/forget state, change button copy and accessibility identifier so it no longer promises deletion.
- Add tests for installed -> delete success, delete failure, disabled -> delete success, and state/cache consistency after relaunch.

### F11 MEDIUM: AVAudioSession interruptions and media-service resets are not handled

Evidence:
- `Dspeech/Core/Audio/LiveAudioSessionRouting.swift:33-41` observes `AVAudioSession.routeChangeNotification`.
- Grep found no production handling for `AVAudioSession.interruptionNotification` or `AVAudioSession.mediaServicesWereResetNotification`.
- `Dspeech/App/CaptureCoordinator.swift:65-70` stops capture on route loss only.

Risk:
- Device-only events such as phone-call interruptions, Siri, other audio capture clients, and media-service reset can leave ASR/session state stale or silently idle.
- Simulator test coverage cannot prove this class of behavior.

Builder requirement:
- Extend routing/events to model interruption began, interruption ended, and media services reset.
- Capture must stop or rebuild deterministically, with visible user state.
- Add fake-routing tests for interruption began while listening, interruption ended while idle, reset while listening, and reset while stopped.

### F12 HIGH: Callsign dictation can lose early buffers and early recognition failures

Evidence:
- `Dspeech/Core/ASR/CallsignDictationService.swift:89-94` starts audio capture before it starts recognition.
- `Dspeech/Core/ASR/CallsignDictationService.swift:90-92` forwards tap buffers directly to `recognizer.append(buffer)`.
- `Dspeech/Core/ASR/CallsignDictationService.swift:183-190` only creates and stores the `SFSpeechAudioBufferRecognitionRequest` inside `startRecognition`.
- `Dspeech/Core/ASR/CallsignDictationService.swift:94-105` ignores every recognition update while `status != .listening`, but `status` is set only after `begin()` returns at `Dspeech/Core/ASR/CallsignDictationService.swift:74-77`.

Risk:
- Any buffer delivered between audio capture start and request creation is dropped through `request?.append`.
- Any immediate `recognitionTask` failure before `status = .listening` is ignored, leaving the service in an idle-looking state.
- This creates the exact "tap mic, nothing happens" failure mode the ASR F1 run was supposed to eliminate.

Builder requirement:
- Build the recognition request/session before admitting tap buffers, or buffer them in a bounded ordered queue until the request is ready.
- Set a distinct `.starting` state before async setup begins, or gate callbacks by session token instead of `isListening`.
- Add tests proving early buffer delivery is not dropped and early recognition failure becomes a visible unavailable/error state.

### F13 HIGH: Primary ASR is not aligned with the iOS 26 Speech north-star

Evidence:
- `docs/ai-kb/2026-05-28-best-practices-north-star.md:45-47` says iOS 26+ primary ASR should be `SpeechAnalyzer` with `SpeechTranscriber`, with `DictationTranscriber` only as fallback and explicit `AssetInventory` lifecycle.
- Production still uses `SFSpeechRecognizer`/`SFSpeechAudioBufferRecognitionRequest` in `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:14-17`, `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:232-256`, and `Dspeech/Core/ASR/CallsignDictationService.swift:169-192`.
- `rg "SpeechAnalyzer|SpeechTranscriber|DictationTranscriber|AssetInventory" Dspeech` finds only locale-availability support, not the live ASR engine.
- Apple WWDC25 SpeechAnalyzer session presents `SpeechAnalyzer`/`SpeechTranscriber` as the new iOS 26 speech-to-text API, with async audio input/results, model asset handling, and on-device transcription.

Risk:
- The codebase is polishing a legacy ASR adapter while the documented product bar is current iOS 26 APIs.
- The legacy adapter already required custom lifecycle restarts, generation tokens, simulator exceptions, and silent-failure patches. This is a sign the app is fighting the old API shape.

Builder requirement:
- Produce an ADR-backed ASR engine plan before touching broad ASR code:
  - `SpeechAnalyzerLiveTranscriptionEngine` as primary for iOS 26 hardware where `SpeechTranscriber` is available;
  - `DictationTranscriber` or current `SFSpeechRecognizer` adapter only as explicit fallback, never silent fallback to cloud;
  - explicit `AssetInventory` support/download/install state, behind user action and source/size disclosure;
  - reusable audio buffer stream/deep-copy/conversion seam shared by main transcription and callsign dictation;
  - tests that exercise adapter selection, asset-state gating, local-only invariants, and fallback reasons.
- If builder decides not to migrate in this iteration, write the blocking reason as an ADR/update and keep F13 open. Do not silently call the legacy path "done".

### F14 HIGH: Device-only Speech happy path can pass without a transcript

Evidence:
- `DspeechTests/OnDeviceSpeechRecognitionTests.swift:87-105` is named `recognizesSynthesizedSpeechEndToEnd`.
- `DspeechTests/OnDeviceSpeechRecognitionTests.swift:95-103` accepts a `kAFAssistantErrorDomain#1110` failure as a successful outcome.
- `DspeechTests/OnDeviceSpeechRecognitionTests.swift:107-115` has a crash-only meter tap test whose final assertion is `#expect(Bool(true))`.

Risk:
- A physical-device run can still fail to recognize synthesized speech and report green.
- This weakens the only lane meant to prove the primary device capability that the Simulator cannot prove.

Builder requirement:
- Split crash-repro tests from capability tests by name and acceptance.
- The device ASR capability test must require a non-empty transcript, or it must be reported as skipped/inconclusive with a recorded reason. A no-speech error cannot close the ASR happy-path gate.
- Crash-repro tests should assert concrete postconditions where possible: no crash plus expected terminal state, visible error, or emitted event.

### F15 HIGH: Network-deny tests are proxy checks, not a full local-only egress proof

Evidence:
- `DspeechTests/ReplayKitNetworkDenyTests.swift:67-74` explicitly says broad tests use `registerGlobalProtocol: false`.
- `DspeechTests/ReplayKitNetworkDenyTests.swift:311-359` runs a deterministic replay transcriber under a scoped deny guard; it does not start Apple Speech or model-pack download.
- `DspeechTests/ReplayKitNetworkDenyTests.swift:361-375` constructs `AppleSpeechLiveTranscriptionEngine` and routes one buffer through `VoiceFilterSpeechAudioBufferGate`, but never calls `engine.start()`.
- `DspeechTests/ReplayKitNetworkDenyTests.swift:429-440` proves only the custom guarded `URLSession` fails, not that production network-capable paths are covered.
- `Dspeech/Core/VoiceFilter/SpeakerModelPackInstaller.swift:88-101` performs real model-pack download via `DownloadUtils.downloadRepo`, which is intentionally outside the post-install no-egress lane.

Risk:
- The suite can say "local-only zero network" while testing deterministic fakes and construction-only paths.
- Apple Speech and FluidAudio/model-pack code paths may use APIs that do not pass through the scoped `URLProtocol` guard.

Builder requirement:
- Rename existing tests so their names match what they prove: deterministic replay no-egress, construction/gate no-egress, local verifier no-egress.
- Add a real post-install local-only egress gate:
  - installed model-pack fixture;
  - live engine or adapter selected for local-only mode;
  - voice-filter gate active;
  - no model download state;
  - no transcript/audio/metadata egress observable through injectable network seams and a process-level network-deny lane where feasible.
- Add a separate explicit download-phase test that allows only the documented model source, never audio/transcript payloads.
- For Apple Speech, document which network APIs can and cannot be intercepted locally, and make physical-device offline verification part of the gate.

### F16 HIGH: FluidAudio acquisition has no source-override seam

Evidence:
- `docs/adr/0008-local-speaker-model-pack-readiness.md:40` requires the model source to be overridable.
- `docs/research/2026-05-25-fluid-audio-speaker-identifier-contract.md:192-196` requires `ModelRegistry.baseURL` before acquisition and records the resolved source.
- FluidAudio docs state models auto-download from HuggingFace by default and recommend `ModelRegistry.baseURL` as the programmatic app override.
- `Dspeech/Core/VoiceFilter/SpeakerModelPackInstaller.swift:39-42` hardcodes identifier/version/source metadata.
- `Dspeech/Core/VoiceFilter/SpeakerModelPackInstaller.swift:88-101` calls install/download without any injected source configuration.
- `Dspeech/Core/VoiceFilter/SpeakerModelPackInstaller.swift:233-241` calls `DownloadUtils.downloadRepo(.diarizer, to: cacheRoot, ...)` directly.
- `rg "ModelRegistry|REGISTRY_URL|baseURL" Dspeech DspeechTests` finds no production/test override seam.

Risk:
- The app tells users the model source is explicit, but the code cannot redirect acquisition to a controlled mirror or local test server.
- Source override is one of ADR 0008's privacy/supply-chain controls; without it, model acquisition remains tied to upstream defaults and cannot be deterministically tested.

Builder requirement:
- Introduce a `ModelPackSource` or `ModelRegistryConfiguring` seam before acquisition.
- Set/restore `ModelRegistry.baseURL` or the equivalent FluidAudio registry control only for the acquisition scope.
- Record the resolved source in `InstalledModelPack.source` and surface it in UI copy.
- Add source-override tests using a local/file/mirror URL and assert acquisition honors it.
- Add a production guard that never changes registry source during post-install classify/enroll paths.

### F17 MEDIUM: Canonical AI docs contain stale contradictions

Evidence:
- `docs/ai-kb/2026-05-28-best-practices-north-star.md:138` says `ContentView` has a failed model-pack retry button with an empty action.
- Current code at `Dspeech/App/ContentView.swift:991-996` wires `voicefilter-modelpack-retry` to `startDownload()`.
- `docs/product/app-store/privacy-nutrition-labels-mapping.md:51` describes model-pack acquisition as `DiarizerModels.downloadIfNeeded`, while current production uses `DownloadUtils.downloadRepo` in `Dspeech/Core/VoiceFilter/SpeakerModelPackInstaller.swift:237-241`.

Risk:
- This project is AI-operated. Stale canonical docs become executable misinformation for the next Claude-builder run.
- Builders can waste work fixing closed issues or miss the real current gap (`DownloadUtils.downloadRepo` with no source override).

Builder requirement:
- After code fixes and tests pass, refresh `docs/ai-kb/current-context.md`, the north-star open action notes, and app-store privacy mapping to match the current code.
- Do not rewrite ADR history; add superseding notes where needed.
- Add a lightweight doc-state check to the final review: any "open contradiction" must map to current code evidence.

### F18 MEDIUM: CI retries failing tests without a separate flake audit

Evidence:
- `.github/workflows/ci.yml:40-50` enables `-test-iterations 3` and `-retry-tests-on-failure`.
- The current review already found tests that can pass without proving the stated capability (`F9`, `F14`, `F15`).

Risk:
- Retries are reasonable for hosted-runner XCUITest noise, but without a flake-report artifact they normalize nondeterminism.
- A top-studio-quality suite should distinguish "transient infra recovered" from "product behavior is deterministic".

Builder requirement:
- Keep retries only if CI exports a flake summary or xcresult evidence for first-attempt failures.
- Add a local no-retry command as the authoritative developer gate on mac24.
- Any test requiring retry in local runs must be treated as failing until the root cause is fixed.

### F19 HIGH: Voice enrollment recorder has nondeterministic stop semantics and no direct tests

Status after Codex implementation pass: addressed. `VoiceEnrollmentRecorder` now owns capture sessions by UUID, ingests copied tap buffers through a serial stream consumer, drains accepted buffers during async stop, ignores late or stale callbacks, and has ten recorder-level unit tests in the app test target.

Evidence:
- `Dspeech/Core/ASR/VoiceEnrollmentRecorder.swift:64-70` installs an AVAudioEngine tap, converts the buffer, then appends to `collected` through `Task { @MainActor ... }`.
- `Dspeech/Core/ASR/VoiceEnrollmentRecorder.swift:81-88` calls `teardown()` and immediately returns the current `collected` snapshot.
- `Dspeech/App/ContentView.swift:830-844` sends that immediate snapshot into `pipeline.enrollPilot`.
- `rg "VoiceEnrollmentRecorder" DspeechTests DspeechUITests` returns no direct recorder tests. Existing `VoiceFilterPipeline` tests cover vector enrollment from supplied samples, not recorder capture lifecycle.
- The main ASR engine already has a safer pattern at `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:33-39`, `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:188-222`, and `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:388-403`: deep-copy tap buffers, send them through a stream, cancel/finish the producer and consumer during cleanup, and guard stale callbacks.

Risk:
- Tap callbacks already queued before or around `stop()` can append after `teardown()` and after `stop()` has snapshotted samples. The enrollment can therefore store a truncated voice sample.
- A stale callback from a prior recording session can append into the next session's `collected` array unless generation/session ownership is enforced.
- This is the same AI failure pattern as callsign dictation: a tap callback satisfies Swift syntax but does not prove lifecycle ordering.

Builder requirement:
- Refactor `VoiceEnrollmentRecorder` behind an injectable recorder/capture seam. Unit tests must not require a real microphone.
- Do not append directly from one detached tap callback task into the shared session array. Use a serial consumer, actor, or explicit generation token so stop/restart ownership is deterministic.
- Define the stop contract precisely: either drain accepted buffers before returning, or intentionally cut off at stop and ignore every later buffer. The UI and tests must match that contract.
- Add tests for: start success, mic denied, invalid input format, engine start failure, duplicate start idempotence, stop with samples, stop with no samples, late buffer after stop ignored, stale prior-session buffer ignored, and restart clearing old samples.

### F20 MEDIUM: Audio-route category priming failure is swallowed before Start availability is computed

Evidence:
- `Dspeech/Core/Audio/LiveAudioSessionRouting.swift:16-25` explains that priming `.playAndRecord` is required so `currentRoute` and `availableInputs` expose microphones before capture starts.
- The same block uses `try? session.setCategory(...)`, so a category failure becomes invisible.
- `Dspeech/App/AudioSourceController.swift:18-27` calls `refresh()` during init, and `Dspeech/App/AudioSourceController.swift:53-64` derives available/selected inputs from `routing.availableInputSnapshots` and `routing.currentRouteSnapshot`.
- `Dspeech/Core/Audio/AudioSessionRouting.swift:3-8` exposes route snapshots and preferred-input selection, but no bootstrap/preparation result that can carry this failure into UI or tests.

Risk:
- If category priming fails, the app can show no input or wrong Start availability while the real error is an audio-session configuration failure.
- This is another silent-boundary failure: the code knows the category call is required, but erases the result.

Builder requirement:
- Add an explicit routing bootstrap/preparation state or event for category priming failure.
- Surface the failure in `AudioSourceController`/Settings with a typed user-visible message.
- Add fake-routing tests for bootstrap success and category failure before route refresh. Do not rely on real `AVAudioSession` in unit tests.

### F21 MEDIUM: AirPlay is pinned as a suitable capture input without device evidence

Evidence:
- `docs/research/2026-05-23-audio-route-health.md:63-69` says `airPlay` as input is rare and should be treated as `unknownExternal` until a real-world example exists.
- `docs/run-notes/2026-05-23-route-health-ux.md:191-194` records the AirPlay-as-suitable-external decision as an unchanged open product question.
- Current code contradicts that safer posture: `Dspeech/Core/Audio/RouteHealthTypes.swift:54-58` does not treat `.airPlay` as output-only, and `Dspeech/Core/Audio/RouteHealthClassifier.swift:32-38` classifies `.airPlay` as `.suitableExternal`.
- `DspeechTests/RouteHealthClassifierTests.swift:106-119` asserts AirPlay is not output-only, and `DspeechTests/RouteHealthClassifierTests.swift:186-193` pins `.airPlay` as suitable external with a synthetic fixture.

Risk:
- The route banner can show green `EXT` and Start can remain enabled for an output-oriented transport that may not provide cockpit audio capture.
- The test is not evidence of hardware behavior; it only locks in a questionable assumption.

Builder requirement:
- Replace `airPlayIsSuitableExternal_pinningCurrentBehavior` with a product-backed contract.
- Either provide a real AVAudioSession route fixture/probe showing AirPlay appears as a valid input route for the intended capture path, or classify AirPlay as `unknownExternal` / unsuitable until proven.
- Update copy/tests so route health never over-promises capture suitability for output transports.

### F22 MEDIUM: FluidAudio SDK version policy is inconsistent with the pinned model manifest

Evidence:
- `Dspeech/Core/VoiceFilter/SpeakerModelPackInstaller.swift:39-45` hardcodes model-pack identifier/version/source and a checksum manifest for the FluidAudio speaker model files.
- `Dspeech.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:5-11` currently resolves FluidAudio to version `0.14.7`.
- `Dspeech/Tools/SpeakerEval/Package.swift:12-14` uses an exact FluidAudio dependency at `0.14.7`.
- The app target's Xcode package reference is looser: `Dspeech.xcodeproj/project.pbxproj:235-240` uses `upToNextMajorVersion` with minimum `0.14.7`.
- `.github/workflows/ci.yml:33-52` runs `xcodebuild build test`, but there is no release/CI assertion that the resolved FluidAudio version still equals the model manifest version.

Risk:
- The production app can be package-updated to a later FluidAudio minor/patch while the installer still labels and verifies a `0.14.7` model-pack contract.
- For an SDK that owns model-download helpers and CoreML loading behavior, version drift is a privacy/supply-chain concern, not only a compile concern.

Builder requirement:
- Choose one release policy and encode it:
  - exact FluidAudio `0.14.7` in the app package reference while the manifest/checksums are version-specific; or
  - a tested upgrade policy that regenerates model checksums/source metadata and proves the SDK/model contract on every version bump.
- Add a CI/release check that fails if `Package.resolved`, `SpeakerModelPackInstaller.packVersion`, and the expected manifest policy diverge.
- Keep the host `SpeakerEval` package and app target on the same reviewed FluidAudio version unless an ADR explicitly separates them.

### F23 MEDIUM: Model-pack download progress has no session ownership token

Evidence:
- `Dspeech/App/ContentView.swift:787-808` cancels the previous `downloadTask`, transitions to `.acquiring`, starts a new unstructured `Task`, and forwards installer progress through `Task { @MainActor ... }`.
- The progress callback at `Dspeech/App/ContentView.swift:792-798` only checks `if case .acquiring = modelPackState`; it does not verify that the callback belongs to the current download attempt.
- `cancelDownload()` at `Dspeech/App/ContentView.swift:811-815` cancels the task and transitions to `.absent`, but a late progress callback from the canceled attempt can still run after the user starts a new attempt and sees `.acquiring` again.
- Existing UI tests at `DspeechUITests/DspeechUITests.swift:85-134` only prove the CTA moves to acquiring/installed, and `DspeechUITests/DspeechUITests.swift:177-198` only proves a launch-argument acquiring state renders `42%`. No test covers cancel -> retry -> late progress from the canceled attempt.

Risk:
- A stale progress event from an old download can overwrite the visible progress of a new download.
- This is the same async-ownership problem already solved elsewhere in the app with generation tokens (`LiveTranscriptionViewModel` translations and `AppleSpeechLiveTranscriptionEngine` recognition callbacks). Model acquisition should meet the same bar because it is user-visible, stateful, and privacy-sensitive.

Builder requirement:
- Move model-pack acquisition into a small testable controller/service, not inline SwiftUI state.
- Add a download attempt ID/generation token. Progress, completion, and failure may commit only if they belong to the current attempt.
- Add unit tests with an injected installer fake for: progress accepted for current attempt, late progress ignored after cancel, late completion ignored after cancel, retry ignores old progress, retry accepts new progress, and cancellation leaves persisted state truthful.

### F24 MEDIUM: App-language picker over-promises localization coverage

Evidence:
- `Dspeech/App/ContentView.swift:616-633` exposes an app-language picker and writes `AppleLanguages`, with copy telling the user to restart.
- `Dspeech/App/ContentView.swift:470-475` offers 10 app language choices.
- `Dspeech/Localizable.xcstrings` currently contains 32 string keys.
- A code scan found 87 distinct Cyrillic string literals in `ContentView.swift`, with 61 not present in `Dspeech/Localizable.xcstrings`. Missing examples include `Dspeech/App/ContentView.swift:689` (`Фильтр диспетчер/пилот`), `Dspeech/App/ContentView.swift:706` (`Позывной воздушного судна`), `Dspeech/App/ContentView.swift:730` (`Голосовой фильтр ATC`), `Dspeech/App/ContentView.swift:865-879` (model-pack install copy), and `Dspeech/App/ContentView.swift:950` (`Записать голос`).
- UI tests launch only Russian (`DspeechUITests/DspeechUITests.swift:283-292`) and do not prove English/Spanish/French/etc. settings surfaces render without mixed Russian UI.

Risk:
- The app can offer a language switcher while large settings and voice-filter surfaces remain Russian after restart.
- This is a product polish and trust issue: a professional app should either fully localize the advertised surfaces or not advertise app-language switching yet.

Builder requirement:
- Decide the product contract:
  - either fully localize all user-visible strings for the advertised languages; or
  - temporarily remove/limit the app-language picker until localization is complete.
- Add an automated localization coverage check that fails when new user-visible Swift strings are not in the string catalog, allowing only explicit non-localized identifiers/technical tokens.
- Add at least one UI smoke for a non-Russian language that opens Settings and verifies key headings/buttons are localized and no Russian-only voice-filter/settings copy is visible.

### F25 MEDIUM: Release readiness can accept a stale unsigned archive

Evidence:
- `scripts/release/check-release-ready.sh:70-73` only checks that `tmp/release/Dspeech.xcarchive` exists and has `Products` plus `Info.plist`.
- The current local archive `tmp/release/Dspeech.xcarchive/Info.plist` has `CreationDate = 2026-06-01 19:25:57 +0000`.
- Current worktree is dirty (`Dspeech/Core/ASR/CallsignDictationService.swift` modified and this review spec untracked), so that archive cannot be treated as proof of the current source state.
- `rg "git status|diff-index|CreationDate|build-unsigned-archive" scripts/release docs/release .github/workflows` shows no check tying the archive to the current commit/source tree.

Risk:
- If screenshots exist, release readiness can pass with an old archive built from different code.
- This is a classic artifact-existence gate: it proves a file is present, not that the release candidate is current.

Builder requirement:
- Make release readiness either build the unsigned archive itself or require a verifiable build stamp that records commit SHA, dirty/clean state, build settings, and archive creation source.
- Fail release readiness on dirty production code unless an explicit review-only artifact allowlist is in use.
- Add a test or shell self-check fixture proving a stale/mismatched archive fails.

### F26 MEDIUM: Debug speech probe source is still compiled from the app target

Evidence:
- `Dspeech/App/DspeechApp.swift:6-34` gates the `--dspeech-sfspeech-probe` launch path behind `#if DEBUG`.
- `Dspeech/App/SimulatorSpeechProbe.swift:1-196` itself is not wrapped in a file-level `#if DEBUG`.
- `Dspeech.xcodeproj/project.pbxproj:57`, `:140`, `:178`, and `:207` include `SimulatorSpeechProbe.swift` in the main `Dspeech` app target sources.
- The current Release simulator binary did not contain the probe marker strings after dead stripping, but that was verified only by an ad hoc binary scan, not by a release gate.
- The Release output map at `tmp/codex-review-derived/Build/Intermediates.noindex/Dspeech.build/Release-iphonesimulator/Dspeech.build/Objects-normal/arm64/Dspeech-OutputFileMap.json` still lists `SimulatorSpeechProbe.swift` with `SimulatorSpeechProbe.o` and `SimulatorSpeechProbe.bc`.

Risk:
- A diagnostic harness that requests Speech authorization, transcribes fixture paths, and writes probe JSON lives in the app target instead of a separate tool/test harness.
- The release guarantee relies on current optimizer/dead-strip behavior plus the `DspeechApp` call site guard. That is weaker than a source-level target boundary.

Builder requirement:
- Move the simulator probe out of the app target into `Dspeech/Tools/` or a dedicated test/probe target, or wrap the entire probe file in `#if DEBUG`.
- Add a release check that scans the built app binary for probe marker strings and fails if they appear.
- Keep probe documentation and launch arguments in a tool/runbook, not in the shipping app surface.

### F27 HIGH: Simulator local-only ASR can use server recognition while the UI still says LOCAL

Evidence:
- `Dspeech/App/ContentView.swift:41-46` constructs `AppleSpeechLiveTranscriptionEngine` for the main app surface.
- `Dspeech/App/ContentView.swift:333-335` and `Dspeech/App/ContentView.swift:375-392` show the `LOCAL` privacy badge from `PrivacyMode.localOnly`.
- `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:235-244` sets `request.requiresOnDeviceRecognition = false` under `#if targetEnvironment(simulator)`.
- `DspeechUITests/DspeechUITests.swift:283-292` launches simulator UI tests in local-only mode, but `DspeechUITests/DspeechUITests.swift:54-82` does not assert that Start stays offline or that the badge changes when the simulator fallback is used.

Risk:
- On mac24 simulator, tapping Start in the main app can route live mic audio through Apple's non-on-device Speech path while the visible badge still says `LOCAL`.
- This does not ship to iPhone device builds, but it breaks the project's local verification story: local simulator tests can exercise a privacy mode that is not what the UI claims.

Builder requirement:
- Do not use server recognition in the main local-only simulator app path.
- If simulator Speech fallback is needed, keep it inside an explicit probe/tool mode with unmistakable debug copy, not under the normal `LOCAL` UI.
- Add a simulator Start/network-deny test or explicit fake-engine UI test proving the main app local-only path does not rely on server recognition.

### F28 MEDIUM: Start is not idempotent while startup is in progress

Status after Codex implementation pass: addressed. Startup now has generation ownership at the engine boundary, a view-model `startInFlight` gate, coordinator Stop coverage during startup, and deterministic suspended-start tests.

Evidence:
- `Dspeech/App/ContentView.swift:284-289` launches `Task { await toggleListening() }` from the Start button.
- `Dspeech/App/CaptureCoordinator.swift:36-42` guards only route health, then calls `live.start()`.
- `Dspeech/App/LiveTranscriptionViewModel.swift:65-70` always calls `engine.start()` and only starts event observation if needed.
- `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:80-82` ignores only `status == .listening`; a second Start while status is `.requestingPermission` can enter startup again.
- `DspeechTests/LiveTranscriptionViewModelTests.swift` and `DspeechTests/CaptureCoordinatorTests.swift` assert single start calls in normal paths, but `rg "duplicate|idempot" DspeechTests/LiveTranscriptionViewModelTests.swift DspeechTests/CaptureCoordinatorTests.swift` found no duplicate/in-flight Start test.

Risk:
- Fast double taps or overlapping UI tasks can issue multiple permission/start attempts before the engine reaches `.listening`.
- Startup owns AVAudioSession, AVAudioEngine taps, Speech requests, and recognition tasks; this path needs session ownership, not a best-effort status check.

Builder requirement:
- Add an explicit `.starting` / startup-in-flight state or generation token at the coordinator/view-model boundary.
- Start must be idempotent for idle -> starting -> listening, and Stop must cancel or cleanly supersede a startup in progress.
- Add tests for duplicate Start while permission/start is suspended, Stop during startup, route loss during startup, and retry after startup failure.

### F29 LOW: Stale source comments still describe green tests as missing/RED

Status after Codex implementation pass: addressed. The stale RED/missing-seam prose was removed while preserving current behavior contracts.

Evidence:
- `DspeechTests/UtteranceWindowRouterTests.swift:21-25` says the seam does not yet exist in production and the tests are RED until the engineer lands it.
- `DspeechTests/SerialBufferRouterTests.swift:14-17` says the same about `SerialBufferRouter`.
- Current production files exist: `Dspeech/Core/ASR/UtteranceWindowRouter.swift` and `Dspeech/Core/ASR/SerialBufferRouter.swift`.
- The local unit and full simulator test runs passed.

Risk:
- Stale comments are AI residue: they turn old implementation instructions into false current architecture memory.
- Future agents can waste work trying to implement seams that already exist or distrust tests that are now green.

Builder requirement:
- Remove stale "not yet exists" / "RED until engineer lands" prose from source tests.
- Keep only current behavior contracts and concise test intent.
- Add a lightweight source hygiene review for stale implementation-phase language in changed files.

### F30 HIGH: Release app links the whole FluidAudio SDK surface, including unrelated ASR/TTS downloaders

Evidence:
- `tmp/codex-review-derived/SourcePackages/checkouts/FluidAudio/Package.swift:10-14` exposes a single `FluidAudio` library product backed by one `FluidAudio` target.
- `Dspeech.xcodeproj/project.pbxproj:169`, `:191`, and `:239-240` link that single `FluidAudio` product into the main app.
- Release simulator binary scan found strings for unrelated SDK surfaces and model downloaders: `Qwen3ASR`, `Parakeet`, `CohereTranscribe`, `WhisperMelSpectrogram`, `KokoroAne`, `PocketTts`, `StyleTTS2`, `Supertonic3`, `DownloadUtils`, `FluidInference/...`, and `https://huggingface.co`.
- `du -sh tmp/codex-review-derived/Build/Products/Release-iphonesimulator/Dspeech.app/Dspeech` reports a 12 MB Release simulator executable, with `FluidAudio.o` at 15 MB before final link/dead strip.
- No FluidAudio `*.xcprivacy` file was found in the checked-out package.
- `.github/workflows/ci.yml:91-141` validates only the app's `Dspeech/PrivacyInfo.xcprivacy`; it does not inspect third-party SDK manifests, linked SDK network domains, or release-binary SDK surface.

Risk:
- Dspeech needs speaker diarization/embedding, but the app binary carries unrelated ASR, TTS, voice-generation, resource-downloader, and HuggingFace model-source surfaces.
- This increases App Review/privacy-review burden, binary size, supply-chain review scope, and the chance that an unrelated SDK API or downloader becomes reachable in a future AI-authored change.
- The privacy label and local-only story become harder to defend when the binary contains many model downloaders unrelated to the product surface.

Builder requirement:
- Decide the SDK integration boundary:
  - use a slim/forked FluidAudio target exposing only diarization/speaker embedding and required download helpers; or
  - keep the full SDK only behind a reviewed ADR that accepts the binary/privacy/supply-chain cost and explains why a slimmer integration is not viable.
- Add a release binary scan that flags unrelated model downloader/synthesis/ASR strings unless an ADR explicitly allowlists them.
- Add a third-party SDK privacy review artifact covering FluidAudio's lack of bundled privacy manifest, required-reason APIs, network domains, model repositories, and downloader entry points.

### F31 MEDIUM: Empty on-device locale availability creates an invalid fallback selection

Evidence:
- `Dspeech/Core/Settings/OnDeviceLocaleAvailability.swift:17-31` can return an empty on-device-capable set only when Apple reports no on-device support at all; that is a real availability state, not a normal language list.
- `Dspeech/Core/Settings/RecognitionSettings.swift:71-108` resolves an empty supported set to the hardcoded fallback identifier `en-US`.
- `Dspeech/Core/Settings/RecognitionSettings.swift:166-179` can set `availableLocales = []` and `localeIdentifier = "en-US"` after `refreshCapableLocales()`.
- `Dspeech/App/ContentView.swift:557-563` renders the picker from `recognition.availableLocales` and has no empty-state/error UI when the list is empty.
- `DspeechTests/RecognitionSettingsTests.swift:105-146` covers narrowed non-empty capable sets and download state, but not empty capable availability or recovery from empty to non-empty.

Risk:
- If the iOS Speech APIs temporarily or permanently report no on-device-capable locale, Settings can show an empty picker while the model still points at `en-US`.
- That invalid selection can flow into the live ASR path as though a valid local language were selected, instead of surfacing "no local language model available".

Builder requirement:
- Introduce an explicit recognition availability state: loaded with choices, loading, unavailable/no on-device locales, and error/hiccup if appropriate.
- Do not store or use `en-US` as a fake valid selection when the capable set is empty.
- Add visible Settings copy and accessibility id for "no on-device recognition language available".
- Add tests for empty capable set, empty recognizer-supported set, stored value with empty capable set, recovery from empty -> non-empty, and selected download state after recovery.

### F32 MEDIUM: Unsigned archive script is not hermetic enough for release evidence

Evidence:
- `scripts/release/build-unsigned-archive.sh:11-14` reads build settings through bare `xcodebuild -showBuildSettings` without explicit `DEVELOPER_DIR`, destination, package-resolution flags, or expected-Xcode assertion.
- `scripts/release/build-unsigned-archive.sh:36-44` builds the archive with `generic/platform=iOS`, but still does not set `DEVELOPER_DIR`, disable package resolution, require `Package.resolved`, or stamp the source state.
- This review already hit an environment mismatch: XcodeBuildMCP used the CommandLineTools developer directory and could not find `simctl`; shell commands only became reliable after explicit `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- The screenshot script is stricter by comparison: `scripts/screenshots/capture-app-store-screenshots.sh:167-175` builds with a generic simulator destination plus `-disableAutomaticPackageResolution`, `-onlyUsePackageVersionsFromResolvedFile`, and `-skipPackageUpdates`.

Risk:
- Release archive evidence can be produced under the wrong developer directory or after implicit SwiftPM resolution, while `check-release-ready.sh` later only verifies that an archive exists.
- This is not an observed build failure, but it is a release-process contract gap: the release script does not encode the environment assumptions that made the local verification reliable.

Builder requirement:
- Make release archive creation explicit about `DEVELOPER_DIR`, expected Xcode major/minor, destination for build-settings reads, and SwiftPM no-update/no-resolution policy.
- Record a build stamp in `tmp/release/` with commit SHA, dirty/clean state, Xcode version, destination, Package.resolved checksum, archive path, and build time.
- Make `check-release-ready.sh` validate that stamp against current source state before accepting the archive.

## Claude-builder spec

Builder role: implement fixes, do not reduce scope to passing current tests.

Hard constraints:
- Preserve `PrivacyMode.localOnly` default and no egress under local-only.
- Do not add cloud ASR/MT, StoreKit, billing, App Store submission, outbound ads/DMs, or hardware promises.
- No fake cloud, fake AI, fake transcription, disabled placeholder controls, or empty action buttons.
- Use Swift 6 strict concurrency. Do not hide concurrency problems with `@unchecked Sendable` unless an explicit synchronization invariant exists.
- Keep UI copy truthful: failure states must be visible, not silent.

Implementation tasks:
Already implemented in current Codex patches: tasks 1, 2, 4, 5, 9, 10, 12, 28, and 29. Keep their acceptance gates active for future regressions.

1. Refactor `CallsignDictationService` into a deterministic, testable lifecycle:
   - explicit `CallsignDictationSession` or equivalent pure state machine;
   - serial buffer handoff from AVAudio tap to Speech request;
   - generation token to ignore stale callbacks after stop/restart;
   - typed error mapping for benign no-speech vs hard Speech errors;
   - cleanup that cannot append into an ended request.
2. Add `CallsignDictationServiceTests.swift` with all F1 cases above.
3. Replace translation boolean-only failure with typed translation UI state:
   - missing pack;
   - unsupported source/target/pair;
   - engine failure;
   - prepare/download failure;
   - user cancellation separately from genuine failure.
4. Replace `InputLevelMetering` `AsyncStream<Double>` with typed meter events and surface meter errors in Settings.
5. Make persisted audio input reapply non-silent and test rejected OS selection.
6. Make corrupt `VoiceFilterStorage` and `ModelPackStateStorage` distinguishable from absent/default.
7. Add or update tests for every changed contract.
8. Split `ContentView.swift` into focused SwiftUI files and move embedded state transitions into testable helpers where appropriate.
9. Replace the permissive Start UI smoke with a real happy-path/failure-path pair.
10. Make model-pack delete behavior truthful and tested: either real filesystem uninstall or renamed non-delete action.
11. Add AVAudioSession interruption/media-reset event handling and fake-routing tests.
12. Fix callsign dictation setup ordering so early buffers and early recognition failures cannot be dropped.
13. Add an ADR-backed iOS 26 ASR adapter plan and either migrate primary ASR to `SpeechAnalyzer`/`SpeechTranscriber` or explicitly keep F13 open with evidence.
14. Strengthen device Speech tests so the happy path requires a transcript and no-speech is not counted as success.
15. Rework network-deny tests from proxy checks into named, scoped proofs for deterministic replay, post-install local-only runtime, and explicit download phase.
16. Add a FluidAudio source-override seam and tests for acquisition source control.
17. Reconcile stale AI docs and privacy mapping after code/tests are true.
18. Add no-retry local test gate and CI flake evidence for any retried failures.
19. Refactor `VoiceEnrollmentRecorder` into a deterministic capture lifecycle and add recorder-level unit tests that prove stop/restart ordering.
20. Surface audio-route category priming failure before Start availability is computed.
21. Resolve AirPlay route-health classification with real device evidence or a conservative classification.
22. Make FluidAudio SDK/model-pack version policy exact or enforce a tested upgrade workflow.
23. Extract model-pack acquisition lifecycle and add ownership-token tests for cancel/retry/progress.
24. Make app-language switching truthful: complete localization coverage or remove/limit the picker.
25. Make release readiness prove the archive matches the current source state.
26. Move the simulator speech probe out of the app target or add a file-level Debug guard plus release binary scan.
27. Remove server-recognition fallback from the main simulator `LOCAL` path, or isolate it behind explicit probe/debug UI that cannot be confused with local-only.
28. Make Start idempotent during startup and test duplicate/start-stop/route-loss races.
29. Remove stale implementation-phase comments from source tests.
30. Resolve the full-FluidAudio binary surface with a slim integration or ADR-backed allowlist and release scan.
31. Add an explicit no-on-device-locale recognition availability state and tests for empty/recovery cases.
32. Make unsigned archive generation hermetic and stamp release artifacts against current source.
33. Update `docs/ai-kb/current-context.md` only after tests prove the new state.

Acceptance gates:
- Banned-marker grep from `CLAUDE.md` returns empty. Keep the literal pattern disguised in docs so the gate does not match its own instructions.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' CODE_SIGNING_ALLOWED=NO -only-testing:DspeechTests build test` passes.
- Full simulator suite including UI tests passes or every UI failure has an attached xcresult and root cause.
- The Start UI happy-path test fails if Start leaves the app idle with no visible typed error.
- Model-pack delete either removes files and proves it in tests, or the UI no longer claims deletion.
- `ContentView.swift` is reduced to root composition/main screen responsibilities, and extracted files have direct tests for state transitions they own.
- Any new or retained `@unchecked Sendable` in changed files has a synchronization invariant and a lifecycle/concurrency test.
- Callsign dictation tests prove early tap buffers are queued/appended after request readiness, and immediate recognition failure is surfaced even before `.listening`.
- Voice enrollment recorder tests prove late tap buffers cannot mutate the returned sample set or leak into a restarted recording.
- Audio route tests prove category priming failure is visible and cannot be confused with "no microphone attached".
- AirPlay route health is no longer pinned as suitable capture without real route evidence.
- FluidAudio package version, model-pack version, checksum manifest, and host-eval package are checked for consistency in CI/release readiness.
- Model-pack acquisition tests prove old progress/completion cannot mutate a newer download attempt or a canceled state.
- Localization coverage gate proves every advertised app language has translated key settings/voice-filter/onboarding strings, or the language picker is not shipped.
- Release readiness fails for stale archives or dirty production source instead of accepting artifact existence.
- Release app binary scan fails if simulator probe markers are present.
- Simulator main app Start path under `LOCAL` cannot use server Speech recognition, or the UI clearly exits the local-only contract in an explicit debug/probe mode.
- Duplicate Start while startup is in progress is idempotent and covered by deterministic suspended-start tests.
- Source comments no longer claim current green seams are missing or RED.
- FluidAudio integration either ships a slim diarization-only surface or has an ADR-backed allowlist plus binary scan for unrelated ASR/TTS/downloader strings.
- Recognition Settings has a visible no-on-device-locale state; an empty capable set cannot produce a fake `en-US` valid selection.
- Unsigned archive build and release readiness agree on source stamp, Xcode, destination, Package.resolved checksum, and dirty/clean state.
- ASR engine selection has an ADR or run-note explaining current iOS 26 API alignment. If `SpeechAnalyzer` is not primary, the reason is explicit and reviewable.
- Device Speech happy-path evidence requires a transcript. No-speech may be documented as inconclusive, not success.
- Network-deny evidence is named by what it actually proves and includes a post-install local-only runtime lane, not only deterministic replay or construction-only checks.
- FluidAudio acquisition can be pointed at an explicit source/mirror and records that source in persisted installed-pack state.
- Canonical AI docs have no stale "open contradiction" that contradicts current code.
- Local mac24 test gate is run without retry; CI retry, if kept, reports first-attempt failures.
- Physical-device Speech lane is run before any "device fixed" claim, with result recorded.
- Reviewer re-checks this file item by item.

External references used by reviewer:
- Apple `requiresOnDeviceRecognition`: https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition
- Apple `supportsOnDeviceRecognition`: https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition
- Apple `AVAudioNode.installTap`: https://developer.apple.com/documentation/avfaudio/avaudionode/installtap(onbus:buffersize:format:block:)
- Apple Speech framework overview: https://developer.apple.com/documentation/speech/
- Apple WWDC25 SpeechAnalyzer session: https://developer.apple.com/videos/play/wwdc2025/277/
- Apple `AVAudioSession.mediaServicesWereResetNotification`: https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification
- Apple `AVAudioSession.interruptionNotification`: https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionnotification
- FluidAudio API docs, model registry: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md
