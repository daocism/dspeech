# tester-unit — model-pack execution gate verification

Run ID: `dspeech-builder-20260524T150007Z-0433753d`
Role: tester-unit (independent verification)
Date: 2026-05-24
Verdict: **PASS — gate verified green on device, all five contracts covered.**

## Commit under test

- Engineer commit: `3dfc246 fix(voice-filter): gate speaker model execution`
- Branch tip tested: `e024f20 docs(voice-filter): record model-pack execution gate run` (docs-only commit on top of `3dfc246`; merged ff-only into the test checkout)
- Branch: `origin/feat/local-pilot-voice-filter`

The expected commit named in the brief (`fix(voice-filter): gate speaker model execution`) is present on origin as `3dfc246`. It was authored under the `AI Office tester-unit` identity (not `engineer-generic`), and it bundles the production gate change with its tests in a single commit. Noted for the echo-chamber record; the diff itself is what was verified.

## Production change verified (Dspeech/Core/VoiceFilter/VoiceFilterPipeline.swift)

- New `requireInstalledModelPack()` throws `LocalSpeakerIdentifierError.modelUnavailable(reason: modelPackState.capabilityReason)` unless `modelPackState.isInstalled`.
- Called at the top of `enrollPilot(...)` and inside `classify(...)` (after the existing `guard enabled, !profiles.isEmpty` early-return, before delegating to the identifier).
- `capability` reports `.unavailable` for an available identifier whenever the pack is not `.installed`.
- All referenced symbols confirmed against real source (`ModelPackState`, `InstalledModelPack`, `ModelPackFailure`, `ModelPackAcquisition`, `UserDefaultsModelPackStateStorage.stateKey`, `LocalSpeakerIdentifierError.modelUnavailable`) — no hallucinated APIs.

## Contract coverage (all five required contracts present and green)

1. Storage round-trips for model-pack states — `roundTripAbsent`, `roundTripInstalled`, `roundTripFailed`, `roundTripDisabled`.
2. `.acquiring` cold-start recovery to `.absent` — `acquiringRecoversToAbsentOnColdStart`.
3. Corrupt/missing state loads `.absent` — `corruptDataLoadsAbsent`, `missingDataLoadsAbsent`.
4. `enrollPilot`/`classify` throw `.modelUnavailable` when identifier available but pack not installed — `absentPackEnrollThrowsModelUnavailable`, `absentPackClassifyThrowsModelUnavailable`, plus `.disabled`-pack variants `disabledPackEnrollThrowsDespitePackMetadata`, `disabledPackClassifyThrowsDespitePackMetadata`, and `absentPackMakesAvailableIdentifierUnavailable`.
5. Installed state allows the fake identifier path — `installedPackMakesCapabilityReady`, `installedPackClassifyDelegatesToIdentifier`.

Determinism: tests use fixed `Date(timeIntervalSince1970:)`, per-test unique `UserDefaults` suite names (`UUID()`), and `defer` cleanup. No real clock / randomness / network.

Scope note: the `classify` gate sits after the `guard enabled, !profiles.isEmpty` early-return, so an empty-profile or disabled-flag pipeline returns `.nonPilot` rather than throwing even when the pack is absent. This matches "nothing to classify" semantics; flagged for the reviewer, not broadened here.

## Exact test command (run on mac24)

```bash
ssh mac24 'cd /Users/andre/projects/dspeech-ios && \
  git fetch origin feat/local-pilot-voice-filter && \
  git merge --ff-only origin/feat/local-pilot-voice-filter && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Dspeech.xcodeproj -scheme Dspeech \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
    -only-testing:DspeechTests CODE_SIGNING_ALLOWED=NO'
```

Destination used as-is: `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4`.

## Result

- `** TEST SUCCEEDED **` — full `DspeechTests` suite green (~20.4s).
- Run twice for determinism (clone `iPhone 17 Pro (44073)` then `(44984)`); identical pass result both runs.
- Failing test names/errors: none.

## mac24 working-tree state

mac24 had unrelated dirty files **left untouched**:

- Modified (tracked): `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift`, `DspeechUITests/DspeechUITests.swift`
- Untracked: `.agent-logs/`, `.agent-prompts/`, `.agent-state/`, `docs/AUTOPILOT-JOURNAL.md`

The ff-only merge advanced `3dfc246..e024f20` (docs/`.ai` only) and did not touch the dirty Swift files. No fix was needed; no source was modified by tester-unit.
