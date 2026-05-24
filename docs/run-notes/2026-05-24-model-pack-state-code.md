# Run note — model-pack state code cycle (closeout) — 2026-05-24

Run: `dspeech-builder-20260524T110035Z-ad6fed3d`
Role: docs-writer (cycle close)
Branch: `feat/local-pilot-voice-filter`
Scope: docs / project-memory only. No Swift, pbxproj, tests, or Hermes/cron touched.

## Outcome: no implementation landed this cycle

The intended slice was the **model-pack state code** — the Swift FluidAudio
model-pack state machine and acquisition UX described as the next slice in the
prior docs cycle (`docs/run-notes/2026-05-24-local-speaker-model-pack.md`) and
in `docs/adr/0008-local-speaker-model-pack-readiness.md`.

No such code landed. Branch HEAD is `d8b7534`
(`docs(voice-filter): local speaker model-pack readiness contract`), which is
**docs-only** (ADR 0008 + `docs/eval/local-speaker-model-pack-validation.md` +
the prior `…070042Z…` docs-writer run note). All four worktrees for this run
sit at `d8b7534` with clean status; no new Swift, no new tests, no new commits.

## What each role found (independent confirmation)

- **engineer-generic** — explored the codebase (eval doc, pipeline, storage,
  `ContentView`, `PrivacySettings` template, VoiceFilter dir, pbxproj
  registration) to scope where the model-pack state machine would attach.
  Produced no committed code by end of run; worktree clean at `d8b7534`.
- **tester-unit** — confirmed **no model-pack state/storage/capability code or
  tests exist** anywhere on the branch; the only `ModelPack` matches are docs/
  `.ai` markdown, and the `https://` hits in ADR 0008 are prose source
  citations (FluidAudio repo, Apple docs), not network code. `LocalSpeakerIdentifier.swift`
  and `VoiceFilterTests.swift` are from the prior ADR-0007 cycle, unchanged.
  mac24 reachable (iOS 26.4.1 host); worktree clean. No fresh full-suite green
  count was captured in this run's recorded stream, so none is claimed here; the
  last recorded green baseline remains 105/105 unit at the pre-wiring point noted
  in `.ai/project-state.md`.
- **reviewer** — flagged the discrepancy directly: there is no model-pack
  *state code* to review, only docs. Did not rubber-stamp.

## Why no code

The "model-pack state code" slice was dispatched against a branch where the
prior cycle had deliberately frozen the *contract* (ADR 0008 + eval plan) but
not the implementation. The implementation slice was not carried out this
cycle. The honest closeout is that the branch is still at the
contract-frozen, no-real-speaker-ID state: `UnavailableLocalSpeakerIdentifier`
remains the default adapter and `LiveTranscriptionViewModel` still synthesizes
`.nonPilot(bestPilotScore: 0)` for every segment. No pilot voice is filtered yet.

## Tests / build status

Docs-only closeout — no code modified, so no `xcodebuild` run was warranted for
this note. Branch code state is unchanged from `d8b7534`. Markdown cross-links
checked: this note ↔ ADR 0008 ↔ `docs/eval/local-speaker-model-pack-validation.md`
↔ prior run note resolve.

## Notion caveat

No Notion connector is available in this run's environment, and task
`369dfa2b-7893-814c-be7e-e7cea26486a6` returned `NOT_FOUND` at planning time —
the same result recorded by previous Dspeech runs. No Notion write was
attempted or fabricated. Per `CLAUDE.md` ("Notion is a read model only; this
repo is canonical"), status lives here in repo docs.

## Next highest-leverage slice (unchanged)

The next slice is the same one ADR 0008 and the prior run note already framed,
and it remains the highest-leverage product work:

Wire a concrete `FluidAudioSpeakerIdentifier` behind the ADR 0008 model-pack
state machine — SPM-add FluidAudio, implement `absent → downloading →
installed/verified` acquisition UX (explicit CTA + size disclosure +
cancel/retry/delete, `AssetInventory`-style), persist pack state via an injected
storage protocol (mirroring `PrivacySettings` + `PrivacySettingsStorage`), swap
the identifier into `VoiceFilterPipeline(identifier:)` only when `installed`,
and land the network-deny integration test plus the replay fixtures from
`docs/eval/local-speaker-model-pack-validation.md`. That slice is what finally
lets `LiveTranscriptionViewModel` stop synthesizing `.nonPilot(bestPilotScore: 0)`.

`docs/ai-kb/current-context.md` was reviewed and left unchanged: the next
context pointer did not materially change this cycle (the slice is still
pending, the canonical-memory and ADR guidance already cover it).
