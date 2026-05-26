# ADR 0007 — VoiceFilter: phase-1 callsign-only, phase-2 FluidAudio (deferred)

Status: Accepted
Date: 2026-05-22
Authors: tech-lead (Mr.Dao dispatch `notion-20260522T070523Z-ab0d0878a53fbebf`)
Supersedes: none
Related: ADR 0001 (iOS-first / local-first), ADR 0002 (privacy: local-only by default), `docs/research/2026-05-21-local-atc-speaker-filter.md`

## Context

The "отделение диспетчера от голосов пилотов" feature (pilot-vs-ATC voice separation) requires two independent capabilities:

1. **Speaker classification** — decide whether each speech segment is one of the enrolled pilot voices (drop) or non-pilot (keep, transcribe). Requires on-device VAD + speaker-embedding + cosine match against enrolled centroids.
2. **ATC-relevance filtering** — when the configured aircraft callsign is set, keep ATC utterances addressed to *our* callsign (and a sliding continuation window after a match), suppress utterances addressed to other traffic.

The CEO's research brief `docs/research/2026-05-21-local-atc-speaker-filter.md` recommends FluidAudio for capability #1. As of the 2026-05-22 verification update appended to that brief, FluidAudio's license (Apache-2.0), SPM package (`v0.14.7`), and public API are confirmed clean, but **its CoreML weights are not bundled in the SPM — they auto-download from HuggingFace on first use.** That conflicts with the literal reading of ADR 0002 "no audio/network at runtime in `.localOnly`" unless we add an explicit, user-gated, AssetInventory-style "Download voice-filter pack" CTA plus a post-download network-deny integration test. Neither artifact exists today.

Capability #2 (callsign filter) does **not** depend on FluidAudio at all. Its pipeline (`ATCTranscriptGate` + `CallSign`) works on the ASR transcript text and is already wired and unit-tested in `Dspeech/Core/VoiceFilter/`.

## Decision

We split the feature into two phases and ship phase 1 today.

### Phase 1 — callsign-only ATC-relevance filter (this branch, today)

- The `VoiceFilterPipeline` is wired into `LiveTranscriptionViewModel`. After each `.segment` event from the ASR engine, the VM calls `pipeline.decide(text:, speaker: .nonPilot(bestPilotScore: 0))` — i.e. we treat every segment as non-pilot, because we have no real speaker classifier in this build.
- `LocalSpeakerIdentifier` is wired as `UnavailableLocalSpeakerIdentifier` (the explicit, throw-on-call stub already in the tree). Calling `enroll(...)` or `classify(...)` throws `.modelUnavailable(reason:)` with a string that names this ADR. No fake classifier output. No fake embeddings. No silent no-op.
- Settings UI exposes:
  - Enable toggle ("Фильтр диспетчер/пилот"). Default OFF on fresh install.
  - Callsign text field (parsed by `CallSign(raw:)`).
  - Continuation-window seconds (default 8 s).
  - A capability banner that surfaces `pipeline.capability == .unavailable(reason:)` verbatim, so the user sees exactly why pilot enrollment slots are disabled.
- Pilot 1 / Pilot 2 enrollment slots are visible in the UI in a **disabled** state. The "Записать голос" button is disabled with subtitle "Локальная модель распознавания голоса не установлена в этой сборке (см. ADR 0007)". This is the dispatched fallback per the run brief: *"Implement the best verified local fallback, keep the API explicit, document the blocker, and leave the Notion task partial with exact evidence."*
- The ATC-relevance gate semantics are exactly those in `docs/research/2026-05-21-local-atc-speaker-filter.md` §"Callsign filter — design recommendation": callsign-match → display; sliding window keep-open → display; otherwise suppress; mixed/low-confidence shown (does not apply today because we synthesize `.nonPilot`).

### Phase 2 — FluidAudio integration (deferred; not in this branch)

Phase 2 unblocks when **all** of the following are true:

1. An on-device pilot-voice enrollment UX exists that explicitly asks the user to download the FluidAudio model pack on first use, with size disclosure and a kill switch — modeled on Apple `AssetInventory` / `SpeechTranscriber` locale assets.
2. A network-deny integration test exists in `DspeechTests/` (or `DspeechUITests/`) that runs the post-enrollment pipeline with all egress to `huggingface.co` blocked and verifies zero failed/pending requests outside the documented download phase. The CEO brief Open Question #5 names this artifact.
3. The FluidAudio `VadManager` + `DiarizerManager` (or `OfflineDiarizerManager`) wiring lives behind a concrete `LocalSpeakerIdentifier` implementation, named e.g. `FluidAudioSpeakerIdentifier`, swapped in via `VoiceFilterPipeline(identifier:)` only when the model pack is installed.
4. `ModelRegistry.baseURL` is set so that, if Andrei chooses, we can mirror weights from a CDN under our control rather than HuggingFace — same pattern as Apple speech assets.

Until those four conditions are met, we do not import FluidAudio as an SPM dependency. We do not vendor partial wrappers. We do not call out to HuggingFace from any build of this app.

## Consequences

Positive:

- Today's branch ships real, verified value: the callsign-relevance gate. Pilots can set their tail number (or any working callsign) in Settings and have non-addressed ATC traffic suppressed from the transcript pane.
- The `LocalSpeakerIdentifier` protocol shape is locked in this branch, so phase 2 is a pure substitution, not a redesign.
- ADR 0002 "local-only by default" is upheld literally: zero network calls beyond Apple `SpeechTranscriber`/`DictationTranscriber` asset download (already accepted) and the user-opt-in cloud path (out of scope here).
- The Notion task partial-completion is documented with exact evidence — research brief verification block + this ADR.

Negative / known limitations:

- Pilot voices are **not** filtered yet. If a pilot says the configured callsign in a readback, today's gate displays it (we synthesize `.nonPilot`, the matcher sees `.callSignMatch`, returns display). This is a known phase-1 limitation; phase 2 fixes it.
- Two of the eight aviation failure modes in `docs/research/2026-05-21-local-atc-speaker-filter.md` (rows 1 "pilot readback contains callsign", 3 "pilot 1 + pilot 2 + ATC overlap") are only fully addressed in phase 2.
- The Settings UI exposes pilot-enrollment affordances as disabled — visible to the user as "feature not yet available", not as a fake button that does nothing. This is intentional per ADR 0002 and per the dispatch fallback rule.

## Test plan

- Existing unit tests in `DspeechTests/VoiceFilterTests.swift` and `DspeechTests/CallSignTests.swift` continue to cover all paths of `SpeakerMatcher`, `ATCTranscriptGate`, `VoiceFilterPipeline`, `VoiceFilterStorage`, and `CallSign`.
- New unit tests in `DspeechTests/LiveTranscriptionViewModelTests.swift` cover the VM↔pipeline wiring: enabled-with-callsign-suppresses, enabled-with-match-displays, disabled-passes-through.
- mac24 `xcodebuild test` on iPhone 17 Pro / iOS 26.4 simulator runs the Dspeech unit-test suite green before the branch is committed.
- Manual simulator/device smoke of the Settings sheet remains a follow-up before TestFlight; unit coverage verifies the VM↔pipeline filter behavior and the UI section is compile-checked by the app target.

## Open questions (tracked for phase 2)

- AssetInventory-style download UX for FluidAudio model pack: button copy, size disclosure source-of-truth, kill switch behavior.
- CDN mirror strategy: do we host weights on our own object store, or accept HuggingFace as a one-time download with explicit user consent?
- Pilot enrollment: clean-speech capture flow (30-60 s), re-enrollment trigger (drift detection), embedding storage location (Keychain vs Core Data).
- Two-pilot enrollment overlap: how do we distinguish Pilot 1 from Pilot 2 during capture if both share a headset?
