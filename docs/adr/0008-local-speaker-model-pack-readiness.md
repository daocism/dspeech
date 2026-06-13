# ADR 0008 — Local speaker model-pack readiness contract

Status: Accepted
Date: 2026-05-24
Authors: docs-writer (AI Office run `dspeech-builder-20260524T070042Z-10c88f5f`)
Supersedes: none
Related: ADR 0001 (iOS-first / local-first), ADR 0002 (privacy: local-only by default), ADR 0004 (no hardware purchase / cable testing), ADR 0007 (VoiceFilter phase-1 callsign-only, phase-2 FluidAudio deferred), `docs/research/2026-05-21-local-atc-speaker-filter.md`, `docs/eval/local-speaker-model-pack-validation.md`

## Context

ADR 0007 deferred real pilot-vs-non-pilot speaker classification to "phase 2" and listed four unlock conditions, but it did not specify *how* a speaker model package is acquired, what states the app moves through while acquiring it, or what counts as proof that the privacy promise survived the acquisition. This ADR is that contract. It exists so the next code cycle can add a concrete `LocalSpeakerIdentifier` backend (FluidAudio/CoreML or equivalent) without re-litigating the privacy guardrails or shipping a fake.

Today's branch is honest about the gap. The default adapter wired in `Dspeech/App/ContentView.swift:15` is `UnavailableLocalSpeakerIdentifier()` (`Dspeech/Core/VoiceFilter/LocalSpeakerIdentifier.swift:27`); its `enroll(...)` and `classify(...)` throw `LocalSpeakerIdentifierError.modelUnavailable(reason:)`, and `LiveTranscriptionViewModel.swift:70` synthesizes `.nonPilot(bestPilotScore: 0)` for every segment because no classifier exists. No pilot voice is filtered yet — the product surface says so rather than pretending otherwise (CLAUDE.md hard rules 2 and 3).

The recommended backend (FluidAudio, `https://github.com/FluidInference/FluidAudio`) is Apache-2.0 and ships a clean Swift/CoreML API for VAD, speaker-embedding extraction, and diarization, with 256-dimensional embeddings that match `UnavailableLocalSpeakerIdentifier.embeddingDimension`. The unavoidable friction: **its CoreML weights are not bundled in the SPM.** Per the FluidAudio README, "Models auto-download on first use" from `huggingface.co`, with a `ModelRegistry.baseURL` / `REGISTRY_URL` override for mirroring. A silent first-use download violates the literal reading of ADR 0002 ("no audio/transcript/metadata leaves the device when `privacy.allowCloud == false`"). The same gating logic Apple documents for its own on-device speech assets applies here: on-device recognition is only guaranteed once the model is present, and absent that support the framework falls back to network (`SFSpeechRecognizer.supportsOnDeviceRecognition`, https://developer.apple.com/documentation/Speech/SFSpeechRecognizer/supportsOnDeviceRecognition).

## Decision

A speaker model package is treated as a first-class, user-gated asset with an explicit state machine. No build of Dspeech may import or run a speaker model backend until acquisition is explicit, observable, and reversible by the user.

### Model-pack states

The model pack is one of exactly these states. The concrete backend exposes them; the UI renders them; tests assert on them.

| State | Meaning | What the user sees | What the engine may do |
|---|---|---|---|
| `absent` | No pack on device. Default for a fresh install. | Enrollment slots disabled; capability banner explains why (mirrors today's `VoiceFilterCapability.unavailable(reason:)`). A "Download voice-filter pack" CTA with size disclosure. | Nothing. `classify`/`enroll` throw `modelUnavailable`. Pipeline synthesizes `.nonPilot(bestPilotScore: 0)`, exactly as `LiveTranscriptionViewModel.swift:70` does today. |
| `downloading` / `importing` | The one-time acquisition is in progress, initiated by an explicit user tap. | Determinate progress, byte count, cancel button. | Network egress permitted **only** to the configured model source for the duration of this state. No audio/transcript egress, ever. |
| `installed` / `verified` | Pack present, checksum/dimension verified, offline-operable. | Enrollment enabled; capability banner clears. | `enroll`/`classify` run fully on-device. Zero network. |
| `failed` / `retry` | Acquisition or verification failed (network, checksum, dimension mismatch, disk). | Plain error reason (no stack traces — security.md), a "Retry" CTA, and a "Continue without voice filter" path that returns to `absent` behavior. | Nothing. Falls back to `absent` engine behavior. |
| `disabled` | Pack present but the user turned the feature off, or a kill switch removed it. | Toggle OFF; optional "Remove pack to reclaim space" action. | Nothing. Pipeline behaves as `absent`. |

State transitions are one-directional except `failed → downloading` (retry) and `installed ⇄ disabled` (toggle), and `installed → absent` (user deletes the pack). The app must survive process kill in any state and recover to a consistent state on next launch (a half-downloaded pack resolves to `absent` or `failed`, never `installed`).

### Network / privacy contract

1. **No audio, transcript, or derived metadata ever leaves the device** in any state, including `downloading`. The download channel carries model bytes in one direction only.
2. **Any model download/import is a one-time, explicit, user-initiated event** with size disclosure before the first byte. No silent auto-download on first `classify`/`enroll`. The backend must be configured so that a missing pack throws (today's behavior) rather than triggering an implicit fetch.
3. **Post-install operation must be offline-verifiable.** After `installed`, the full enroll→classify→route pipeline must run with all egress blocked and produce zero failed or pending network requests. This is the network-deny test required by ADR 0007 condition 2 and specified in `docs/eval/local-speaker-model-pack-validation.md`.
4. **The model source is overridable.** The backend exposes the equivalent of `ModelRegistry.baseURL` so weights can be mirrored to a source under our control rather than a third-party host, without code change. Default source and any override are recorded in the eval doc and surfaced in the download UX.
5. **The privacy badge contract (CLAUDE.md hard rule 4) is unaffected.** `LOCAL`/`CLOUD` continues to reflect `privacy.allowCloud`; the model-pack download is not a "cloud mode" and must not flip the badge.

### Acceptance gates for the next implementation cycle

The next cycle that wires a real backend must land all of the following in the same branch before the feature is considered shippable behind its toggle:

- A concrete `LocalSpeakerIdentifier` (e.g. `FluidAudioSpeakerIdentifier`) swapped into `VoiceFilterPipeline(identifier:)` **only** when the pack is `installed`/`verified`; `absent`/`failed`/`disabled` keep `UnavailableLocalSpeakerIdentifier`.
- The model-pack state machine above, persisted via an injected storage protocol (the `PrivacySettings` + `PrivacySettingsStorage` template in `Dspeech/Core/Settings/`), with a round-trip test.
- The download/import UX: explicit CTA, size disclosure, progress, cancel, retry, delete — modeled on Apple `AssetInventory` for speech locale assets.
- The network-deny integration test from the eval doc, green on the iPhone 17 Pro / iOS 26.4 simulator.
- Replay-fixture evidence (the eval doc's offline lane) demonstrating pilot/non-pilot/mixed/insufficient decisions, since no real cockpit hardware is available (ADR 0004).
- Embedding-dimension agreement asserted in test (256, matching `UnavailableLocalSpeakerIdentifier.embeddingDimension` and the FluidAudio embedding size).
- The capability banner and disabled-slot copy updated to reflect the live states instead of the static ADR-0007 "not installed in this build" string.

No App Store / TestFlight submission of this feature before the offline lane *and* at least the simulator evidence lane in the eval doc are green (CLAUDE.md hard rule 6, ADR 0006).

## Rejected alternatives

- **Fake classifier / synthetic embeddings.** Returning a plausible-looking `SpeakerMatchDecision` without a real model would silently mis-route ATC audio and break CLAUDE.md hard rules 2 and 3. The honest `UnavailableLocalSpeakerIdentifier` throw stays until a real backend lands.
- **Silent auto-download on first use.** FluidAudio's default first-use HuggingFace fetch, left unguarded, violates ADR 0002. We require the explicit `absent → downloading` user-initiated transition instead. (FluidAudio README: "Models auto-download on first use… set an HTTPS proxy"; the override hook is `ModelRegistry.baseURL`.)
- **Cloud speaker identification.** Sending audio to a server for diarization is categorically out under ADR 0002 and the App Store privacy promise. Apple's own framework illustrates the failure mode: without on-device support the recognizer requires network (`supportsOnDeviceRecognition`). We will not build a path that can leak audio.
- **App Store / TestFlight before real-model + replay evidence.** Shipping the enrollment UX against a stub, or before the offline replay lane proves decisions, would put an unvalidated safety-adjacent filter in front of pilots. Deferred until the eval-doc gates pass (ADR 0006, ADR 0004).

## Consequences

Positive:

- The next code cycle has a frozen contract: states, transitions, privacy invariants, and acceptance gates are decided, so backend integration is substitution, not redesign (continues the ADR 0007 protocol-first posture).
- The privacy promise is preserved *through* model acquisition, not just at runtime — the one network event is explicit, bounded, one-directional, and offline-verifiable afterward.
- Mirror-ability (`baseURL` override) keeps a path off third-party hosting if Andrei wants it later.

Negative / known limitations:

- Pilot voices remain unfiltered until the next cycle ships the backend; today's `.nonPilot(bestPilotScore: 0)` synthesis is unchanged.
- This ADR does not certify flight safety, transcription correctness, or diarization accuracy. It is an acquisition/privacy contract; correctness thresholds live in `docs/eval/local-speaker-model-pack-validation.md` and remain unproven until that lane runs.
- Real-hardware (wired intercom) validation is still future work per ADR 0004; the eval doc defines a matrix that does not require buying hardware now.

## Sources

- FluidAudio (Apache-2.0, Swift/CoreML VAD + diarization + speaker embedding; SPM `https://github.com/FluidInference/FluidAudio.git`; first-use HuggingFace download; `ModelRegistry.baseURL` override): https://github.com/FluidInference/FluidAudio
- Apple `SFSpeechRecognizer.supportsOnDeviceRecognition` (on-device requires recognizer support, else network): https://developer.apple.com/documentation/Speech/SFSpeechRecognizer/supportsOnDeviceRecognition
- Internal: ADR 0002, ADR 0004, ADR 0007; `docs/research/2026-05-21-local-atc-speaker-filter.md`; `docs/eval/local-speaker-model-pack-validation.md`

## 2026-06-13 update — phase-2 enabled by default (shippable behind its toggle)

The acceptance gates above are met in-tree, so `VoiceFilterFeatureFlag.speakerDiarizationEnabled`
now defaults **on** (was gated behind `-dspeech.voicefilter.diarization.enable`, which Release
never passed). `-dspeech.voicefilter.diarization.disable` is the new test/safety kill switch.

Gate evidence:

- **Real backend, install-gated** (line 47): `FluidAudioSpeakerIdentifier` is built only when the
  pack is `installed`/`verified` via `FluidAudioBackendBuilder`; `absent`/`failed`/`disabled` keep
  `UnavailableLocalSpeakerIdentifier`.
- **Persisted state machine + round-trip test** (line 48), **download/import UX** (line 49),
  **256-dim embedding assertion** (line 52), **live-state capability copy** (line 53): present and
  covered by `DspeechTests` + the `DspeechUITests` voice-filter tests, which are now un-skipped in
  `Dspeech.xctestplan` so they gate on every PR/main run (the feature ships, so its tests gate).
- **Network-deny integration test green on the simulator** (line 50): `ReplayKitNetworkDenyTests`.
- **Offline replay lane green** (line 51): the "Offline ATC voice-filter replay eval" CI lane.
- **Thresholds calibrated** from real FluidAudio measurements (`SpeakerMatchConfig.default`), plus a
  real-ATC host harness (`scripts/testdata/run-atc-eval.py`) proving the safety property — across a
  rotating cohort, real out-of-window ATC segments that reached the cosine comparator were **never**
  classified `.pilot` (no controller suppressed), with void controls and a comparator-reached floor
  guarding against a vacuous pass.

Safety posture is unchanged for a fresh install: with no installed pack and no enrolled pilot the
pre-ASR speaker path fails open to `.nonPilot` — nothing is suppressed until the user explicitly
downloads the pack and enrols a voice. The badge contract (line 41) is untouched. The App Store /
TestFlight submission gate (line 55, ADR 0006, CLAUDE.md rule 6 — explicit Andrei sign-off) remains
in force and is **not** satisfied by this change.
