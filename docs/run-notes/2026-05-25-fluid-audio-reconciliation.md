# 2026-05-25 — FluidAudio speaker-identifier slice reconciliation

Run: `dspeech-builder-20260525T190042Z-c2188fe3`
Role: engineer-backend (ubuntu-vm; mac24 Claude logged out, SSH used only for read-only git checks)
Branch: `feat/local-pilot-voice-filter`

## Outcome

The branch was already coherent around the landed offline FluidAudio speaker-identifier
slice on `origin/feat/local-pilot-voice-filter` (`4fe4a44`), a clean fast-forward
superset of the local checkout. No code reconciliation was needed; no dirty state
existed. See `.ai/runs/dspeech-builder-20260525T190042Z-c2188fe3-canonical-recovery.md`
for the full git-topology decision (no `git reset --hard`).

This run is **doc-only**: it corrects `docs/ai-kb/current-context.md` (which still
claimed `UnavailableLocalSpeakerIdentifier` was the only conformer) and records final
state. Code on origin is accepted as-is after source verification below.

## Source verification of accepted slice behavior

Verified by reading the source at `4fe4a44`; all accepted behaviors hold:

- **Default build fails open.** `LocalSpeakerIdentifierFactory.make` returns
  `UnavailableLocalSpeakerIdentifier` unless `state == .installed(pack)` **and** a
  `LocalSpeakerBackendBuilder` is injected
  (`Dspeech/Core/VoiceFilter/LocalSpeakerIdentifier.swift`).
- **Installed pack must carry a local model path + the required FluidAudio files.**
  `FluidAudioBackendBuilder.makeIdentifier(for:)` throws `.modelUnavailable` when
  `pack.localModelPath` is nil/empty, and when either `pyannote_segmentation.mlmodelc`
  or `wespeaker_v2.mlmodelc` is absent (`fileExists` injected, default
  `FileManager.default`) — `Dspeech/Core/VoiceFilter/FluidAudioSpeakerIdentifier.swift`.
- **Fail closed on missing files / dimension mismatch / load error.** The factory
  catches any builder throw and any post-build dimension/availability mismatch and
  returns `UnavailableLocalSpeakerIdentifier`; the adapter additionally throws
  `.incompatibleDimension(expected:got:)` when the embedding length ≠ 256
  (WeSpeaker) and `.modelUnavailable` when `DiarizerModels.load` / `extractSpeakerEmbedding`
  raises.
- **Real offline FluidAudio API.** `FluidAudioDiarizerHandle` calls
  `DiarizerModels.load(localSegmentationModel:localEmbeddingModel:)` against local
  file URLs and `manager.extractSpeakerEmbedding(from:)` — no network path, no
  `downloadIfNeeded` in the identifier itself (acquisition is a separate, explicit
  installer step). Matches the upstream contract in
  `docs/research/2026-05-25-fluid-audio-speaker-identifier-contract.md`.
- **Classify before ASR, discard only confident pilot speech.**
  `VoiceFilterPipeline.routeBeforeTranscription(speaker:)` returns
  `.discard(reason: .pilotVoice)` **only** for `.pilot`; `.mixed`, `.insufficientSpeech`,
  and `.nonPilot` all return `.transcribe(...)`, and the gate short-circuits to
  `.transcribe` when disabled or no profile is enrolled
  (`Dspeech/Core/VoiceFilter/VoiceFilterPipeline.swift`).
- **Not a flight-safety guarantee.** Stated in ADR 0008 (line ~75) and the eval plan.
- **No placeholders** in `Dspeech/Core/VoiceFilter/` (`grep TODO|FIXME|NotImplemented|fatalError`
  → none).

## Build/test evidence

Not re-run in this doc-only run. The functional end-to-end verification for this code
was recorded for the `4fe4a44` lineage in `.ai/project-state.md` (2026-05-25 entry:
iPhone 17 Pro / iOS 26.4, `DspeechTests` + Start/download UI tests green).
Re-verification of the pushed head is handed to tester-unit (below).

## Handoff to tester-unit

- **Commit SHA to test:** the head of `feat/local-pilot-voice-filter` after this run's
  doc commit is pushed (doc-only; does not change the Swift sources verified above).
  The Swift code under test is unchanged from `4fe4a44`.
- **Exact mac24 command** (deterministic, throwaway detached worktree at the pushed head):

  ```bash
  ssh mac24 'cd /Users/andre/projects/dspeech-ios && \
    git fetch origin && git checkout --detach origin/feat/local-pilot-voice-filter && \
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild -project Dspeech.xcodeproj -scheme Dspeech \
      -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
      CODE_SIGNING_ALLOWED=NO build test'
  ```

- **Expected scheme/destination:** scheme `Dspeech`, destination
  `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4`.
- **Expected result:** `** TEST SUCCEEDED **`; `VoiceFilterTests` (incl. factory
  fail-open / fail-closed cases) green.
