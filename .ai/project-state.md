# Dspeech - aviation cockpit / ATC transcription (iOS) - Runtime project state

> Updated by the `orchestrator` and `tech-lead` roles after every dispatch.
> Mirrors high-level state only; per-run summaries/handles live under `.ai/runs/`.

Project ID: `dspeech`
Task prefix: `[Dspeech]`
Canonical registry: `/home/user/projects/MyInfra/config/project-workspaces/projects.yaml`

## Current phase

Project Workspace bootstrap landed: canonical AI memory skeleton exists in this repo, and MyInfra contains the Dspeech registry + project team definitions.

## Active branches

- `project-workspace-bootstrap-20260521` — adds this project-memory skeleton.

## Last successful run

2026-05-22: Local pilot voice filter core landed on `feat/local-pilot-voice-filter`: enrollment stores voiceprint + callsign, pre-STT pilot suppression route, mixed-speaker safe transcribe policy, ATC callsign/continuation gate indicators, mac24 simulator tests passed. Real FluidAudio adapter/UI wiring remains next.

2026-05-21: Mr.Dao/tech-lead Project Workspace bootstrap rendered `.ai/` and `docs/ai-kb/`, updated `AGENTS.md` / `CLAUDE.md`, and verified docs-only diff hygiene.
