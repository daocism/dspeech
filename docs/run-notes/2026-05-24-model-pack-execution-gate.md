# Run note — model-pack execution gate

Date: 2026-05-24
Run ID: `dspeech-builder-20260524T150007Z-0433753d`
Branch: `feat/local-pilot-voice-filter`
Commit: `3dfc246` — `fix(voice-filter): gate speaker model execution`

## What changed and why

Commit `743f3a0` added `ModelPackState`, persistence, and truthful UI, but
`VoiceFilterPipeline` still let an *available* injected identifier run
`enroll`/`classify` while the pack was `.absent`, `.acquiring`, `.failed`, or
`.disabled`. That contradicted ADR 0008's installed-only / no-silent-auto-download
contract: a future FluidAudio backend (which auto-downloads CoreML weights from
HuggingFace on first use unless gated) could have fetched on first `enroll`.

This slice makes the existing state machine an actual execution gate.

### Production (`Dspeech/Core/VoiceFilter/VoiceFilterPipeline.swift`)

- New private `requireInstalledModelPack()` throws
  `LocalSpeakerIdentifierError.modelUnavailable(reason: modelPackState.capabilityReason)`
  unless `modelPackState.isInstalled`.
- Called at the top of `enrollPilot(...)` (before `identifier.enroll`) and inside
  `classify(...)` *after* the existing `enabled && !profiles.isEmpty` fail-open
  return, before `identifier.classify`.
- `capability` already gated on `modelPackState.isInstalled` (unchanged).
- `decide(...)`, `routeBeforeTranscription(...)`, and the callsign text gate are
  untouched — text-only gating needs no model.

No FluidAudio, network, fake download, or placeholder model API was added.

### Tests (`DspeechTests/VoiceFilterTests.swift`)

- `ModelPackStateStorageTests` (new suite): round-trip `.absent` / `.installed` /
  `.failed` / `.disabled`; persisted `.acquiring(...)` recovers to `.absent` on
  cold start; missing data and corrupt data both load `.absent`.
- `VoiceFilterPipelineTests` (added): available + absent ⇒ `capability`
  unavailable, `enrollPilot`/`classify` throw `.modelUnavailable`; available +
  installed ⇒ `capability == .ready`, `enrollPilot` stores a profile, `classify`
  delegates to the identifier; disabled pack ⇒ unavailable + both throw despite
  present pack metadata. Added `InMemoryModelPackStorage` double + `installedPack()`
  helper.
- Existing `enrollmentStoresPilotVoiceAndSpokenCallSign` now injects an installed
  pack (it exercises a real enroll, which the gate now requires).

## Verification

mac24 (`/Users/andre/projects/dspeech-ios`), iPhone 17 Pro / iOS 26.4 sim.
`git fetch` + `git merge --ff-only origin/feat/local-pilot-voice-filter` (mac24
had unrelated dirty files — `AppleSpeechLiveTranscriptionEngine.swift`,
`DspeechUITests.swift`, `.agent-*/`, `docs/AUTOPILOT-JOURNAL.md` — left untouched;
the ff-merge touched none of them).

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Dspeech.xcodeproj -scheme Dspeech \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
  -only-testing:DspeechTests CODE_SIGNING_ALLOWED=NO
```

Result: `** TEST SUCCEEDED **`. All 7 `ModelPackStateStorageTests` and the new
`VoiceFilterPipelineTests` gate cases passed; full `DspeechTests` suite green.
(`DspeechUITests` not run this slice — `-only-testing:DspeechTests` only.)

## Scope boundary / next slice

This proves the *gate*, not the privacy guarantee end-to-end. Still open from
`docs/eval/local-speaker-model-pack-validation.md`: network-deny integration test,
download-phase boundary test, source-override (`baseURL`) test, privacy-badge
invariance across all five states, replay-fixture decisions, threshold
calibration, and embedding-dimension assertion against a live backend. Next
highest-leverage slice: a concrete `LocalSpeakerIdentifier` (FluidAudio/CoreML)
swapped in only when the pack is `installed`, plus the download/import UX
(CTA → progress → cancel → retry → delete) the ADR 0008 acceptance gates require.
