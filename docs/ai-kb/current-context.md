# Dspeech - aviation cockpit / ATC transcription (iOS) - Current Context

> Rolling 1-page pointer. Updated by `knowledge-curator` after every substantive run.
> When this page grows beyond one screen, move older details into a dated archive file next to it.

## What we are building right now

Dspeech is a native iOS 26+ SwiftUI app for receive-only aviation cockpit / ATC transcription, with optional translation later. The active product direction is local-first and privacy-first: no audio, transcript, or metadata leaves the device while cloud privacy is disabled. Current implementation already has the Apple Speech live transcription MVP wired in the app; future work should build on the existing service/protocol boundaries in `Dspeech/Core/ASR/`, `Dspeech/Core/Audio/`, and `Dspeech/Core/Settings/`.

The voice-filter routing path is now landed and verified end-to-end as a *seam*: route-health capture UX, the model-pack execution gate (ADR 0008 installed-only contract), and the **pre-ASR `SpeechAudioBufferGate`** are all wired on `feat/local-pilot-voice-filter`. The pre-ASR gate routes every captured buffer through `VoiceFilterPipeline` before Apple Speech ASR and discards only confidently-classified pilot speech. It is **inert / fail-open in a default build** because the only `LocalSpeakerIdentifier` conformer is `UnavailableLocalSpeakerIdentifier` (throws `.modelUnavailable`): basic routing *is live*, but it never discards until a real on-device speaker model ships.

## Binding decisions

- `CLAUDE.md` hard rules win inside this repo.
- ADRs in `docs/adr/` are append-only source of truth for architecture/product decisions.
- `docs/PLAN-2026-05-18.md` remains the current iteration plan until superseded by a newer dated plan.
- MyInfra Project Workspaces registers this project as `project_id=dspeech` and task prefix `[Dspeech]`.
- Notion is a read model only; this repo + `docs/ai-kb/` + `.ai/project-state.md` is canonical for AI project memory.
- Notion connector returned **NOT_FOUND** for active task `369dfa2b-7893-814c-be7e-e7cea26486a6` (no connector reachable from the run environment); repo run-notes + commit SHAs are the canonical handoff. See `docs/run-notes/2026-05-25-speaker-identifier-slice.md`.

## Current next priority

The voice-filter routing scaffold (route-health UX → model-pack execution gate →
pre-ASR buffer gate) is complete and verified. The next highest-leverage work, in
order:

1. **Real local/offline speaker identifier + explicit model-pack acquisition UX** —
   replace `UnavailableLocalSpeakerIdentifier` with an on-device embedding-backed
   `LocalSpeakerIdentifier` (FluidAudio is the named Phase-2 candidate), gated
   behind a model-pack the user downloads/imports/verifies on-device with **zero
   audio egress** and an explicit acquisition UX (replacing the disabled enrollment
   buttons). Only when a verified pack is present does the pre-ASR gate stop
   fail-opening and actually discard confident pilot speech. The next builder MUST
   first move classification off `@MainActor` with FIFO append ordering (reviewer
   W1) and make discard utterance-aware, not raw-buffer-level (reviewer W2), before
   enabling discard in production.
2. **Replay / source-audio validation kit** — a fixture harness that feeds recorded
   ATC source audio through the ASR + filter pipeline so transcription/filter
   quality is regression-testable without aircraft hardware.
3. **App Store / TestFlight readiness** — signing, TestFlight build, privacy
   nutrition labels, on-device/offline messaging, export compliance — only after
   1 + 2 yield a real installable local build.

## Open questions for Andrei

- Provide or create the dedicated Telegram chat/topic for `[Dspeech] AI Workspace` so Mr.Dao can bind `telegram.chat_id` in MyInfra when ready.
- Confirm when Dspeech should move from repo-level/project-memory bootstrap into live Telegram/WebUI routing.
