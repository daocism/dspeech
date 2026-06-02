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

## Current next priority

2026-06-02b polish (`docs/run-notes/2026-06-02b-polish-icon-signing-install.md`): app icon,
DEVELOPMENT_TEAM signing (Personal Team `NW2XAS56AW`), F5 input-level meter (button-driven),
translation-pack indicator, tap-to-expand, F2 monospaced+Dynamic Type, #if DEBUG probe gate,
preview-safe Canvas, dead-code removal, and a network-deny locator-test isolation fix
(`locateModelDirectory(cacheRoot:)`). Device-install ready (`scripts/run-on-device.sh`,
`docs/DEVICE-INSTALL-WORKFLOW.md`, `docs/ON-DEVICE-TEST-CHECKLIST.md`); **only remaining
user step: enable Developer Mode on the iPhone**. All PRD gates F1-F5/F8/§3 closed; F6/F7
device-only.

2026-06-02 run (`docs/run-notes/2026-06-02-mvp-completion-translation-audio-onboarding.md`):
**MVP feature-completion landed** on `feat/mvp-completion-2026-06-02` (5 commits, suite
green, 0 warnings, device-arch compiles). PRD gates closed: §3 first-run onboarding, F8
background ASR stop, **F3 on-device translation** (Apple Translation framework,
`TranslationSession(installedSource:target:)`, local-only, per-segment gloss, target picker,
pack download via `prepareTranslation`), and **F5 audio source picker** (per-device
persistence). Two adversarial review passes; all confirmed findings fixed (incl. a removed
fake-AI demo-gloss surface and per-segment translation token guards). Deferred + documented:
F5 live input-level meter, in-app `translationUnavailable` surfacing, suppressed-segment
translation skip, `.translationTask` cold-launch UITest. **Remaining before TestFlight:**
device signing (Andrei's Apple ID/Team — none in 1Password) + the ADR 0008 network-deny /
replay validation kit + App Store metadata. Older priorities below remain valid.

2026-06-01 run (`docs/run-notes/2026-06-01-asr-locale-concurrency-interleaved.md`):
landed the live-tap actor-isolation crash fix (ordered `AsyncStream` handoff),
user-configurable recognition locale (the en-US-vs-French ATC defect),
interleaved-PCM-buffer correctness for the external-cable path, exhaustive ICAO/
segmenter tests, and a host-based recognition validation (SFSpeech/SpeechAnalyzer do
not run in the Simulator). The voice-filter routing scaffold (route-health UX →
model-pack execution gate → pre-ASR buffer gate → W1 serial FIFO routing → W2
utterance-window discard) is complete and verified; **both reviewer asks W1 and W2 are
now cleared**. The next highest-leverage work, in order:

1. **VAD / silence-gap utterance segmentation — implemented.** `EnergySilenceSegmenter`
   now cuts the decision window on a trailing-silence utterance edge (≥ `minSilence`
   after ≥ `minSpeech`) or a max-window cap, replacing the fixed sample-count window;
   `SpeechActivitySegmenterTests` pins the cut decisions. The residual PTT-straddle
   risk (reviewer NOTE A) remains — a window spanning a pilot→dispatcher transition
   that scores ≥ `pilotMatchThreshold` (0.72) can still discard co-located dispatcher
   speech — but it is a property of the embedding over real audio, not a router-seam
   gap. Remaining: tune `minSilence`/`energyThreshold` against real ATC, and harden the
   model-pack acquisition UX past the download CTA / enrollment surface.
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
