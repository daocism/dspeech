# tester-unit verification — run `dspeech-builder-20260525T190042Z-c2188fe3`

Role: tester-unit (ubuntu-vm orchestration; mac24 used only for xcodebuild/git/worktree)
Date: 2026-05-25
Branch: `feat/local-pilot-voice-filter`
Slice: recover and verify the local/offline FluidAudio speaker-identifier path behind the installed model-pack gate.

## Commit tested

- **SHA: `2d2da3e1c474c6c24ca32361478cca811e71e567`** (`2d2da3e docs(ai): reconcile branch around landed FluidAudio speaker-identifier slice`) — canonical tip of `origin/feat/local-pilot-voice-filter`.
- Code tip carried by this SHA: `1375e09 feat(voice-filter): working model-pack download and pilot enrollment`, `2b64b71 fix(voice-filter): use real FluidAudio embedding API and offline load`, `d3b2180 build(deps): pin FluidAudio 0.14.7`.
- `a8a643d` (the worktree's starting HEAD) is a strict ancestor of `2d2da3e` with zero local commits ahead — clean fast-forward, no reconciliation surgery needed.

## mac24 dirty-state handling

mac24 main checkout `/Users/andre/projects/dspeech-ios` was on `feat/local-pilot-voice-filter` @ `4fe4a44` with **4 untracked dirty items**:

```
?? .agent-logs/
?? .agent-prompts/
?? .agent-state/
?? docs/AUTOPILOT-JOURNAL.md
```

To avoid clobbering: I never touched the main checkout's HEAD or files. I created an
**isolated detached throwaway worktree** at the exact tested SHA, built/tested there,
then removed it.

```bash
ssh mac24 'cd /Users/andre/projects/dspeech-ios \
  && git fetch origin feat/local-pilot-voice-filter \
  && git worktree add --detach /Users/andre/projects/_dspeech-tester-c2188fe3 2d2da3e'
# ... run tests ...
ssh mac24 'cd /Users/andre/projects/dspeech-ios \
  && git worktree remove --force /Users/andre/projects/_dspeech-tester-c2188fe3 \
  && git worktree prune'
```

Post-cleanup verification: `git worktree list` shows only the original checkout;
`git status --porcelain | wc -l` still reports **4** — the dirty untracked items are
intact and unmodified.

## Command(s) run

```bash
ssh mac24 'cd /Users/andre/projects/_dspeech-tester-c2188fe3 \
  && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  && xcodebuild -project Dspeech.xcodeproj -scheme Dspeech \
       -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
       -only-testing:DspeechTests CODE_SIGNING_ALLOWED=NO build test'
```

- Scheme: `Dspeech`
- Destination: iPhone 17 Pro / iOS 26.4 (prior-verified pattern, still valid)
- Scope: full `DspeechTests` Swift Testing target (covers the changed suites and all dependencies)

## Result: **PASS** — `** TEST SUCCEEDED **`

- **184 `Test case ... passed`**, **0 failed** (counted across full-suite runs).
- Suite ran green across 4 consecutive xcodebuild invocations — no flakiness observed (determinism confirmed for this offline/deterministic suite).

Speaker-identifier / model-pack-gate suites exercised (all green), including:

- `FluidAudioBackendBuilderTests` — `presentBundleFilesProduceAvailableBackendAtDimension256`, `emptyLocalModelPathThrowsModelUnavailable`, `missingModelFilesThrowsModelUnavailable`, `nilLocalModelPathThrowsModelUnavailable`, `bothBundleFilesRequired`, `factoryWithFluidBuilder{DimensionMismatch,MissingFiles,Absent,NilPath}StaysUnavailable`, `disabledPackWithFluidBuilderStaysUnavailable`.
- `LocalSpeakerIdentifierFactoryTests` — `installedWithMatchingBackendBecomesAvailable`, `installedWithDimensionMismatchStaysUnavailable`, `installedWith{Throwing,Unavailable}BackendFailsOpenToUnavailable/StaysUnavailable`, `installedWithoutBackendKeepsPipelineNotReady`, `{absent,disabled,acquiring,failed}StateProducesUnavailable`, `manualModelPathRoundTripsThroughStorage`, `legacyPackJSONWithoutLocalModelPathDecodesToNil`, `factoryBackedPipelineKeepsMixedSpeechTranscribed`.
- `VoiceFilterPipelineTests` — `installedPackMakesCapabilityReady`, `installedPackClassifyDelegatesToIdentifier`, `absentPackMakesAvailableIdentifierUnavailable`, `routeBeforeTranscriptionDiscardsPilotBeforeSTT`, `routeBeforeTranscriptionKeepsMixedSegmentsVisible`, `decideUsesGateWhenEnabled`, `decideRespectsDisabledFlag`, `unavailableIdentifierSurfacesCapability`.
- `SpeechAudioBufferGateTests` — `thrownClassifierErrorFailsOpenToASR`, `routeBeforeTranscriptionFailsOpenForInsufficientSpeech`, `monoFloatSamples*` (empty/stereo-average/mono-extract/non-float-nil).
- `SpeakerMatcherTests`, `VoiceFilterStorageTests`, `ATCTranscriptGateTests`, `ModelPackStateStorageTests`, `SpeakerAudioPreprocessingTests`.
- Plus `CaptureCoordinatorTests`, `RouteHealthMonitorTests`, `RouteHealthClassifierTests`, `LiveTranscriptionViewModelTests`, `PrivacySettingsTests`, `PhoneticCallsignParserTests`, `CallSignTests`, `TranscriptSegmentTests`.

## Failure snippets

None — no failed test cases.

## Acceptance

- Meaningful Xcode evidence recorded: `** TEST SUCCEEDED **`, 184/184 green on iPhone 17 Pro / iOS 26.4 at SHA `2d2da3e`.
- The tested SHA is already committed and pushed on `origin/feat/local-pilot-voice-filter`; the FluidAudio speaker-identifier path is verified landed at `2d2da3e`.
- No tests were weakened. Tests-only artifact (this doc) committed and pushed.
