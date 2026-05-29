# Dspeech - aviation cockpit / ATC transcription (iOS) - Current Context

> Rolling 1-page pointer. Updated by `knowledge-curator` after every substantive run.
> When this page grows beyond one screen, move older details into a dated archive file next to it.

## What we are building right now

Dspeech is a native iOS 26+ SwiftUI app for receive-only aviation cockpit / ATC transcription, with optional translation later. The active product direction is local-first and privacy-first: no audio, transcript, or metadata leaves the device while cloud privacy is disabled. Current implementation already has the Apple Speech live transcription MVP wired in the app; future work should build on the existing service/protocol boundaries in `Dspeech/Core/ASR/`, `Dspeech/Core/Audio/`, and `Dspeech/Core/Settings/`.

The voice-filter routing path is now landed and verified end-to-end as a *seam*: route-health capture UX, the model-pack execution gate (ADR 0008 installed-only contract), the **pre-ASR `SpeechAudioBufferGate`**, a real **offline FluidAudio speaker identifier** (`FluidAudioSpeakerIdentifier` + `FluidAudioBackendBuilder`, behind the installed model-pack gate), and **utterance-window discard granularity** are all wired on `feat/local-pilot-voice-filter`. The pre-ASR gate routes every captured buffer through `VoiceFilterPipeline` before Apple Speech ASR and discards only confidently-classified pilot speech. **Reviewer W1 and W2 are both cleared (run `…29c9c067`, reviewer APPROVE_WITH_NOTES at `977d5a4`):** classification runs off `@MainActor` applying append/discard strictly in capture (FIFO) order (`SerialBufferRouter`, W1), and the discard decision is now made over a coherent ~1.0 s **utterance window** (`Dspeech/Core/ASR/UtteranceWindowRouter.swift`, W2) — buffers are accumulated to `recordingFormat.sampleRate × 1.0 s`, classified once, and appended-all or discarded-all, so a single mislabeled tap buffer can no longer punch a hole in an ATC utterance; sub-threshold windows are never classified and are flushed fail-open on stop. Full `DspeechTests` green on mac24 (iPhone 17 Pro / iOS 26.4): 8 `UtteranceWindowRouterTests` + the 5 W1 `SerialBufferRouterTests` regression guard all pass. A **default build still fails open**: `LocalSpeakerIdentifierFactory.make` returns `UnavailableLocalSpeakerIdentifier` unless an `InstalledModelPack` *and* an injected `LocalSpeakerBackendBuilder` are both present, and `FluidAudioBackendBuilder` itself fails closed to `UnavailableLocalSpeakerIdentifier` on a missing model path, missing `pyannote_segmentation.mlmodelc`/`wespeaker_v2.mlmodelc` files, an embedding-dimension mismatch, or any load error. Discard of pilot speech only becomes live once a user has installed and verified a local pack on-device — and this is explicitly **not a flight-safety guarantee** (ADR 0008).

## Binding decisions

- `CLAUDE.md` hard rules win inside this repo.
- ADRs in `docs/adr/` are append-only source of truth for architecture/product decisions.
- `docs/PLAN-2026-05-18.md` remains the current iteration plan until superseded by a newer dated plan.
- New north-star reference for downstream leads: `docs/ai-kb/2026-05-28-best-practices-north-star.md`. It pins the current Apple/Swift/Speech/privacy/TestFlight source bar, records that ADR 0007 is stale relative to the active FluidAudio-backed branch, and keeps ADR 0008 as the release gate.
- MyInfra Project Workspaces registers this project as `project_id=dspeech` and task prefix `[Dspeech]`.
- Notion is a read model only; this repo + `docs/ai-kb/` + `.ai/project-state.md` is canonical for AI project memory.
- Notion connector returned **NOT_FOUND** for active task `369dfa2b-7893-814c-be7e-e7cea26486a6` (no connector reachable from the run environment — re-confirmed run `…29c9c067`, 2026-05-26); repo run-notes + commit SHAs are the canonical handoff. See `docs/run-notes/2026-05-25-speaker-identifier-slice.md`.
- CI is stop-the-line for Dspeech leads: red GitHub Actions runs must be fixed in-loop, and a real green Actions run is required when CI is the deliverable. The portable Xcode 26 selector lives at `scripts/ci/select-xcode26.sh`; the script-only CI auto-fix watchdog lives at `scripts/ci/dspeech_ci_watchdog.py` with runbook `docs/runbooks/dspeech-ci-autofix-watchdog.md`.

## Current next priority

The voice-filter routing scaffold (route-health UX → model-pack execution gate →
pre-ASR buffer gate → W1 serial FIFO routing → W2 utterance-window discard) is
complete and verified; **both reviewer asks W1 and W2 are now cleared**. The next
highest-leverage work, in order:

1. **VAD / silence-gap utterance segmentation** — the W2 window boundary is a fixed
   1.0 s sample count (`decisionWindowSeconds`), not silence-segmented, so a window
   straddling a pilot→dispatcher PTT transition that scores ≥ `pilotMatchThreshold`
   (0.72) can discard up to ~1 s of co-located dispatcher speech (reviewer NOTE A,
   the only substantive carry-forward; disclosed as a residual risk, not a coverage
   gap — it is a property of the embedding over real audio, not unit-testable at the
   router seam). Replace the fixed window with a VAD silence-gap boundary so decision
   windows align to utterance edges before discard is enabled in production. The
   model-pack acquisition UX past the current download CTA / enrollment surface still
   needs hardening alongside this.
2. **ADR 0008 network-deny integration test + replay / source-audio validation kit**
   — a network-deny test proving zero egress under load, plus a fixture harness that
   feeds recorded ATC source audio through the ASR + filter pipeline so
   transcription/filter quality (and the W2 straddle case) is regression-testable
   without aircraft hardware. Required before enabling discard in production.
3. **App Store / TestFlight readiness** — signing, TestFlight build, privacy
   nutrition labels, on-device/offline messaging, export compliance — only after
   1 + 2 yield a real installable local build.

## Open questions for Andrei

- Provide or create the dedicated Telegram chat/topic for `[Dspeech] AI Workspace` so Mr.Dao can bind `telegram.chat_id` in MyInfra when ready.
- Confirm when Dspeech should move from repo-level/project-memory bootstrap into live Telegram/WebUI routing.
