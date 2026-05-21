# Dspeech - aviation cockpit / ATC transcription (iOS) - Current Context

> Rolling 1-page pointer. Updated by `knowledge-curator` after every substantive run.
> When this page grows beyond one screen, move older details into a dated archive file next to it.

## What we are building right now

Dspeech is a native iOS 26+ SwiftUI app for receive-only aviation cockpit / ATC transcription, with optional translation later. The active product direction is local-first and privacy-first: no audio, transcript, or metadata leaves the device while cloud privacy is disabled. Current implementation already has the Apple Speech live transcription MVP wired in the app; future work should build on the existing service/protocol boundaries in `Dspeech/Core/ASR/`, `Dspeech/Core/Audio/`, and `Dspeech/Core/Settings/`.

## Binding decisions

- `CLAUDE.md` hard rules win inside this repo.
- ADRs in `docs/adr/` are append-only source of truth for architecture/product decisions.
- `docs/PLAN-2026-05-18.md` remains the current iteration plan until superseded by a newer dated plan.
- MyInfra Project Workspaces registers this project as `project_id=dspeech` and task prefix `[Dspeech]`.
- Notion is a read model only; this repo + `docs/ai-kb/` + `.ai/project-state.md` is canonical for AI project memory.

## Open questions for Andrei

- Provide or create the dedicated Telegram chat/topic for `[Dspeech] AI Workspace` so Mr.Dao can bind `telegram.chat_id` in MyInfra when ready.
- Confirm when Dspeech should move from repo-level/project-memory bootstrap into live Telegram/WebUI routing.
