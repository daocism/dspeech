# Run note — speaker-identifier factory/gate slice (2026-05-25)

Run: `dspeech-builder-20260525T070045Z-aac9d282`, worker `engineer-generic`.
Branch: `feat/local-pilot-voice-filter`. Commit: **`fd10aa0`** (rebased onto `0fda374`).

## Path taken: fallback (enabling gate layer), not FluidAudio SPM wiring

The mission's preferred path was wiring the `FluidAudio` SPM product and a
`FluidAudioSpeakerIdentifier`. I took the **fallback path** the mission defines,
because:

- This Xcode project does **not** use `PBXFileSystemSynchronizedRootGroup`; every
  source file is listed manually in `Dspeech.xcodeproj/project.pbxproj`. Adding an
  SPM product + a new backend file requires pbxproj surgery (package reference,
  build-file/file-reference/group/sources entries) that cannot be build-validated
  on `ubuntu-vm` (no Xcode), and CLAUDE.md forbids renumbering existing pbxproj IDs.
- The research contract `docs/research/2026-05-25-fluid-audio-speaker-identifier-contract.md`
  landed concurrently (commit `0fda374`, picked up on rebase), but adding an
  unbuildable SPM dependency blind would violate "no half-implementation".

So this slice lands the substitution point that a FluidAudio backend plugs into,
with **zero new files** (no pbxproj risk) and full green tests.

## Files changed

| File | Change |
|---|---|
| `Dspeech/Core/VoiceFilter/LocalSpeakerIdentifier.swift` | New `protocol LocalSpeakerBackendBuilder` + `enum LocalSpeakerIdentifierFactory.make(state:backendBuilder:)`. Additive; no existing symbol changed. |
| `Dspeech/Core/VoiceFilter/ModelPackState.swift` | `InstalledModelPack.localModelPath: String?` (manual-model-path contract) + explicit init with the param defaulted to `nil`. Backward-compatible Codable (legacy JSON → `nil`). |
| `Dspeech/App/ContentView.swift` | Default pipeline identifier now comes from `LocalSpeakerIdentifierFactory.make(state:)` reading `UserDefaultsModelPackStateStorage`; `backendBuilder` defaults `nil` → stays unavailable today. |
| `DspeechTests/VoiceFilterTests.swift` | New `LocalSpeakerIdentifierFactoryTests` (15 tests). |

## Factory contract (the gate)

`LocalSpeakerIdentifierFactory.make` returns `UnavailableLocalSpeakerIdentifier`
(→ pipeline never `.ready`, no pilot audio dropped before ASR) for **every** case
except a fully-good backend:

- `.absent` / `.acquiring` / `.failed` / `.disabled` → unavailable (uses
  `state.capabilityReason`).
- `.installed` **without** a registered `backendBuilder` (today's shipping reality)
  → unavailable. *Installed-without-backend does not mark the pipeline ready.*
- `.installed` + builder that **throws** → unavailable (fail-open).
- `.installed` + builder whose identifier reports `.unavailable` → unavailable.
- `.installed` + builder whose `embeddingDimension` ≠ `pack.embeddingDimension`
  → unavailable.
- `.installed` + builder returning an available, dimension-matching identifier
  → that concrete identifier (only here does the pipeline become `.ready`).

## Privacy guarantees (unchanged, now enforced through one gate)

- No new network code, no SPM dependency, no cloud path. ADR 0002 intact.
- No silent model download: construction is gated on persisted `ModelPackState`;
  a missing/absent pack yields an identifier that throws `modelUnavailable`.
- `LOCAL`/`CLOUD` badge still bound to `privacy.allowCloud` (untouched).
- UI copy unchanged and still honest: `absentContent` and the `!identifierAvailable`
  banner state the recognizer is not connected in this build — no pilot-suppression
  claim is made unless a real backend is available.

## Tests / build

Verified on mac24 in a **throwaway detached worktree** from the pushed commit, so
the canonical dirty `dspeech-ios` checkout (`AppleSpeechLiveTranscriptionEngine.swift`,
`DspeechUITests.swift`, `.agent-*`, `docs/AUTOPILOT-JOURNAL.md`) was preserved and
untouched.

```bash
# on mac24, throwaway worktree at FETCH_HEAD = fd10aa0
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Dspeech.xcodeproj -scheme Dspeech \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
  -only-testing:DspeechTests CODE_SIGNING_ALLOWED=NO
```

Result: **`** TEST SUCCEEDED **`** (full `DspeechTests` suite, incl. new
`LocalSpeakerIdentifierFactoryTests`). Throwaway worktree removed after; no litter.

## Acceptance gates covered (new tests)

- Pack absent/acquiring/failed/disabled → identifier unavailable (audio never
  dropped pre-ASR; the existing `SpeechAudioBufferGateTests` prove fail-open routing).
- Installed + matching fake backend classifies and **discards a confident pilot**
  segment (`factoryBackedPipelineDiscardsConfidentPilotBeforeASR`).
- Mixed speech stays transcribed (`factoryBackedPipelineKeepsMixedSpeechTranscribed`).
- Installed-without-backend keeps pipeline **not ready**
  (`installedWithoutBackendKeepsPipelineNotReady`).
- `localModelPath` round-trips through storage; legacy JSON decodes to `nil`.

## Next slice

1. Implement `FluidAudioSpeakerIdentifier: LocalSpeakerIdentifier` + a
   `FluidAudioBackendBuilder: LocalSpeakerBackendBuilder` that loads CoreML weights
   from `pack.localModelPath` (no registry auto-download), then pass that builder in
   `ContentView` and register it. Requires adding the `FluidAudio` SPM product and a
   pbxproj edit — do this in a cycle that can `xcodebuild` on mac24 to validate the
   project file.
2. Build the explicit `absent → downloading → installed` acquisition flow + the
   network-deny integration test from `docs/eval/local-speaker-model-pack-validation.md` §1.
