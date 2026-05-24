# Run note — model-pack state code cycle — 2026-05-24

Run: `dspeech-builder-20260524T110035Z-ad6fed3d`
Role: engineer-generic (implementer)
Branch: `feat/local-pilot-voice-filter`
Scope: Swift + pbxproj. No FluidAudio dependency, no network code, no model download, no Hermes/cron.

> Supersedes the earlier docs-writer closeout draft of this same note, which
> recorded "no implementation landed this cycle." That was true at the time it
> was written (branch HEAD `d8b7534`, docs-only). The implementation slice has
> now been carried out. See commit `743f3a0`.

## Outcome: model-pack state shell landed

Commit `743f3a0` (`feat(voice-filter): add model pack state shell`) turns the
ADR 0008 state machine from prose into app behavior, without adding a real
speaker backend. It rebases cleanly on top of the prior docs/`.ai` commits
(`b81e0f1`, `cb24482`, `08f973e`) — no remote commits were lost.

The honest runtime gap is unchanged and deliberate: `UnavailableLocalSpeakerIdentifier`
is still the default adapter and no pilot voice is filtered yet. What changed is
that the app now *accurately represents* model-pack readiness instead of a
single static "not installed in this build" string.

## What landed

- **`Dspeech/Core/VoiceFilter/ModelPackState.swift` (new).** Exhaustive
  `ModelPackState` enum matching ADR 0008: `.absent`, `.acquiring(ModelPackAcquisition)`
  (phase `downloading`/`importing` + clamped progress + optional byte counts),
  `.installed(InstalledModelPack)` (identifier / version / embedding dimension /
  SHA-256 checksum / source / size / installedAt — the metadata needed to prove
  checksum/dimension/source), `.failed(ModelPackFailure)` (typed kind +
  user-safe reason, no stack traces, `isRetryable`), and `.disabled(InstalledModelPack)`
  (pack retained, feature off). Plus `ModelPackStateStorage` protocol and
  `UserDefaultsModelPackStateStorage` (key `dspeech.voicefilter.modelpack.v1`),
  mirroring the `PrivacySettings` + `PrivacySettingsStorage` template. Corrupt
  or missing data decodes to `.absent`; a persisted `.acquiring` resolves to
  `.absent` on cold start via `recoveredAfterColdStart()` (a half-download is
  never resurrected as `.installed`).
- **`Dspeech/Core/VoiceFilter/VoiceFilterPipeline.swift`.** New
  `modelPackStorage` init param (defaulted — every existing call site compiles
  unchanged) and `private(set) var modelPackState`. `capability` now requires
  **both** an available identifier **and** `modelPackState.isInstalled`; an
  available identifier with a non-installed pack reports `.unavailable(reason:)`
  derived from the state. The pipeline is never silently marked ready on
  installed state alone (ADR 0008 §Decision item). `setModelPackState(_:)`
  persists transitions.
- **`Dspeech/App/ContentView.swift` — `VoiceFilterSettingsSection`.** Copy is
  now state-specific: `.absent` shows an explicit disabled "Скачать пакет…" CTA
  with size/source-placeholder copy and no claim that filtering is active;
  `.acquiring` shows determinate progress + cancel; `.installed` shows pack
  metadata and enrollment slots **enabled only when the identifier is actually
  available** (capability banner + disabled slots otherwise); `.failed` shows a
  user-safe reason + retry (disabled, no downloader) + continue-without-filter;
  `.disabled` shows enable + delete-pack. New accessibility identifiers added
  (`voicefilter-modelpack-{absent,acquiring,installed,failed,disabled}`,
  `…-download-cta`, `…-progress`, `…-cancel`, `…-delete`, `…-enable`,
  `…-retry`, `…-continue-without`); existing identifiers
  (`voicefilter-enabled-toggle`, `…-callsign-field`, `…-capability-banner`,
  `…-enroll-pilot1/2`) kept stable.
- **`Dspeech.xcodeproj/project.pbxproj`.** `ModelPackState.swift` registered in
  the app target (build file `…120`, file ref `…121`, VoiceFilter group, Sources
  phase). No existing IDs renumbered (CLAUDE.md constraint).

## Privacy / honesty guardrails respected

- No FluidAudio SPM dependency added, no `ModelRegistry`/`REGISTRY_URL`, no
  network code, no auto-download — the download CTA is disabled because no
  downloader exists yet (CLAUDE.md hard rules 2 & 3; ADR 0008 "no silent
  auto-download").
- No claim that pilot voices are filtered. `LiveTranscriptionViewModel` still
  synthesizes `.nonPilot(bestPilotScore: 0)`; this slice does not change that.
- Privacy `LOCAL`/`CLOUD` badge untouched — the model pack is not a cloud mode.

## Tests / build status

Pushed `08f973e..743f3a0` to `origin/feat/local-pilot-voice-filter`.

mac24 was fast-forwarded with `git fetch` + `git merge --ff-only` (not
`checkout`/`pull`) specifically to preserve its pre-existing unrelated dirty
work — `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift` (M),
`DspeechUITests/DspeechUITests.swift` (M), and untracked `.agent-*/` +
`docs/AUTOPILOT-JOURNAL.md`. Confirmed unchanged before and after the merge; my
commit touches none of those paths.

Command (mac24, iPhone 17 / iOS 26.4 simulator):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme Dspeech \
    -destination "platform=iOS Simulator,name=iPhone 17,OS=26.4" \
    -only-testing:DspeechTests CODE_SIGNING_ALLOWED=NO
```

Result: `** TEST SUCCEEDED **` — **113 / 113 DspeechTests passed, 0 failed**
(xcresulttool summary). This compiles the new file under Swift 6 strict
concurrency and confirms the existing capability/pipeline tests still pass
(`VoiceFilterPipelineTests/unavailableIdentifierSurfacesCapability()` green).

Not yet authored (left to `tester-unit`, per the implementer/tester contract):
round-trip persistence tests for all five `ModelPackState` cases, the
corrupt/missing → `.absent` recovery test, the `.acquiring` cold-start recovery
test, and the capability matrix (available-identifier × non-installed-pack →
`.unavailable`; available × installed → `.ready`). The production code is shaped
to make these injectable (storage protocol; pure state transitions).

## Next highest-leverage slice (unchanged)

Wire a concrete `FluidAudioSpeakerIdentifier` behind this state machine —
SPM-add FluidAudio, implement the real `absent → downloading →
installed/verified` acquisition (explicit CTA + size disclosure + cancel/retry/
delete, with a real downloader replacing the disabled CTA), swap the identifier
into `VoiceFilterPipeline(identifier:)` only when `installed`, and land the
network-deny integration test plus the replay fixtures from
`docs/eval/local-speaker-model-pack-validation.md`. That slice is what finally
lets `LiveTranscriptionViewModel` stop synthesizing `.nonPilot(bestPilotScore: 0)`.
