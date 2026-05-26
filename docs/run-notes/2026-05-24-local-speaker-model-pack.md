# Run note — local speaker model-pack readiness contract — 2026-05-24

Run: `dspeech-builder-20260524T070042Z-10c88f5f`
Role: docs-writer
Branch: `feat/local-pilot-voice-filter`
Scope: docs / project-memory only. No Swift, pbxproj, tests, or Hermes/cron touched.

## Current status

Product-readiness gate authored. The branch still honestly exposes `UnavailableLocalSpeakerIdentifier` as the default adapter (`Dspeech/App/ContentView.swift:15`); `LiveTranscriptionViewModel.swift:70` synthesizes `.nonPilot(bestPilotScore: 0)` for every segment because no real speaker model exists. No pilot voice is filtered yet, and this run does not change that — it removes the *next* blocker by freezing the contract for acquiring and validating a real model pack.

Route-health recovery priority was already satisfied before this run (branch clean; `b671f74` verified by `.ai/runs/dspeech-supervisor-20260524T002321Z-edbbae4a-verification.md`).

## Artifacts created

- `docs/adr/0008-local-speaker-model-pack-readiness.md` — why no model package may be imported/run until acquisition is explicit and user-gated; the five model-pack states (absent, downloading/importing, installed/verified, failed/retry, disabled); network/privacy contract; acceptance gates for the next cycle; rejected alternatives (fake classifier, silent auto-download, cloud speaker ID, App Store/TestFlight before real-model + replay evidence).
- `docs/eval/local-speaker-model-pack-validation.md` — offline verification plan, replay-fixture requirements (no real hardware), pilot/non-pilot/mixed/insufficient thresholds and confidence behavior, future hardware validation matrix (no purchase required), simulator + physical-device evidence checklist.
- This run note.

`docs/ai-kb/current-context.md` was reviewed; left unchanged (its "build on existing service/protocol boundaries" guidance already covers this; ADR 0008 is the new append-only source of truth, no pointer churn needed).

## Tests / build status

Docs-only change. No code modified, so no `xcodebuild` run was warranted or performed — running it would prove nothing about prose. Markdown internal references checked: ADR 0008 ↔ eval doc ↔ run note cross-links resolve, and cited source paths (`LocalSpeakerIdentifier.swift`, `ContentView.swift:15`, `LiveTranscriptionViewModel.swift:70`, `PilotVoiceProfile.swift`) exist on this branch.

## Primary sources cited

- FluidAudio (Apache-2.0; SPM `https://github.com/FluidInference/FluidAudio.git`; first-use HuggingFace download; `ModelRegistry.baseURL` override; 256-dim embeddings): https://github.com/FluidInference/FluidAudio
- Apple `SFSpeechRecognizer.supportsOnDeviceRecognition`: https://developer.apple.com/documentation/Speech/SFSpeechRecognizer/supportsOnDeviceRecognition
- Apple audio route-change docs (validation-lane context): https://developer.apple.com/documentation/avfaudio/responding_to_audio_route_changes

## Notion caveat

The Notion active task for this run is inaccessible from this connector (`NOT_FOUND`). Per CLAUDE.md ("Notion is a read model only; this repo is canonical"), status is recorded here in repo docs instead. No Notion write was attempted.

## Next highest-leverage implementation slice

Wire a concrete `FluidAudioSpeakerIdentifier` behind the ADR 0008 model-pack state machine: SPM-add FluidAudio, implement the `absent → downloading → installed/verified` acquisition UX (explicit CTA + size disclosure + cancel/retry/delete, `AssetInventory`-style), persist pack state via an injected storage protocol, swap the identifier into `VoiceFilterPipeline(identifier:)` only when `installed`, and land the network-deny integration test plus the replay fixtures from `docs/eval/local-speaker-model-pack-validation.md`. That is the slice that finally lets `LiveTranscriptionViewModel` stop synthesizing `.nonPilot(bestPilotScore: 0)` and route real speaker decisions.
