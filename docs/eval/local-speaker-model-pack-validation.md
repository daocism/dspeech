# Local speaker model-pack — validation & readiness plan

Date: 2026-05-24
Owner: docs-writer (AI Office run `dspeech-builder-20260524T070042Z-10c88f5f`)
Status: Plan (not yet executed — no real backend or model pack exists on this branch)
Governs: ADR 0008 (local speaker model-pack readiness contract)
Related: ADR 0002 (privacy), ADR 0004 (no hardware purchase), ADR 0007 (voice-filter phasing), `docs/research/2026-05-21-local-atc-speaker-filter.md`, `docs/eval/audio-input-matrix.md`, `docs/eval/asr-benchmark-plan.md`

> This plan defines how the next implementation cycle proves a local speaker model pack is acquired safely and behaves correctly **before** any pilot relies on it. It does not assert that any of these gates currently pass — they do not, because the only adapter on this branch is `UnavailableLocalSpeakerIdentifier`. Nothing here certifies flight safety or guarantees transcription/diarization correctness.

## 1. Offline verification plan (the privacy gate)

The single highest-priority gate from ADR 0008 §"Network/privacy contract". The feature is not shippable until this is green.

- **Network-deny integration test.** With the model pack in the `installed`/`verified` state, run the full `enroll → classify → routeBeforeTranscription` pipeline against replay fixtures with **all egress blocked** (no route to `huggingface.co` or any host). Assert: zero failed requests, zero pending requests, no thrown network errors, and a correct `SpeakerMatchDecision`/`PreTranscriptionRoutingDecision` for each fixture. Lives in `DspeechTests/` (or `DspeechUITests/` if a device network sandbox is required).
- **Download-phase boundary test.** Assert the *only* network activity in the whole feature occurs during the `downloading`/`importing` state, is one-directional (model bytes in), and targets the configured model source. Audio/transcript bytes never appear on any socket.
- **Missing-pack-throws test.** With the pack `absent`, assert `enroll`/`classify` throw `LocalSpeakerIdentifierError.modelUnavailable(reason:)` and that no implicit download is triggered (no auto-fetch on first use). This pins the "no silent auto-download" decision.
- **Source-override test.** Set the equivalent of `ModelRegistry.baseURL` to a local/mirror URL and assert the download path honors it (so weights can be served from a source under our control).
- **Privacy-badge invariance.** Assert the `LOCAL`/`CLOUD` badge stays bound to `privacy.allowCloud` across all five model-pack states (the download is not a cloud mode).

Apple's framework documents the same gating principle we depend on: on-device recognition is only guaranteed when the model is present, otherwise the framework requires network (`SFSpeechRecognizer.supportsOnDeviceRecognition`, https://developer.apple.com/documentation/Speech/SFSpeechRecognizer/supportsOnDeviceRecognition). Our test asserts the analogous guarantee for the speaker pack.

## 2. Replay-fixture requirements (no real hardware available)

Per ADR 0004 we do not buy cockpit hardware now, so the canonical debugging and validation substrate is recorded/synthesized audio replayed through the pipeline — never live mic capture in CI.

Fixtures (16 kHz mono, matching the `docs/research/2026-05-21-local-atc-speaker-filter.md` pipeline input; align with `docs/eval/audio-input-matrix.md` source profiles):

- **Single enrolled pilot, clean speech** — expect `.pilot(slot:score:)`, routed `pilotVoice` (discarded before STT).
- **Non-pilot / ATC voice, clean** — expect `.nonPilot(bestPilotScore:)`, routed `nonPilotVoice` (kept for STT).
- **Two enrolled pilots on one channel** — both expect `.pilot`, both discarded (research failure mode #8).
- **Overlap: pilot + ATC under PTT leakage** — expect `.mixed(bestPilotScore:)`, routed `mixedOrLowConfidence` → **kept and surfaced** (never silently dropped; research failure mode #3).
- **Too little voiced audio / squelch only** — expect `.insufficientSpeech`, routed `insufficientSpeech`.
- **Pilot readback containing own callsign** — expect speaker filter to discard it upstream; the callsign gate must not re-introduce it (research failure mode #1).
- **Embedding drift after simulated headset change** — re-enrollment fixture; document expected confidence drop (research failure mode #4).

Each fixture carries an expected-decision label so the test is a specification, not a coverage exercise. Fixtures are committed under a test-resources path the test target reads from; no fixture contains PII or real identifiable cockpit recordings without consent.

## 3. Thresholds and confidence behavior

Thresholds are **placeholders to be calibrated on the replay corpus**, not validated values. The behavior contract around them is fixed; the numbers are not.

| Decision | Condition (cosine vs enrolled centroids) | Routing | Display |
|---|---|---|---|
| `pilot` | best score ≥ `pilotMatchThreshold` (start ~0.70, calibrate) | discard before STT | not transcribed |
| `nonPilot` | best score < `nonPilotCeiling` (start ~0.55, calibrate) | keep for STT | transcribed; callsign gate may apply |
| `mixed` | `nonPilotCeiling` ≤ best score < `pilotMatchThreshold` | keep for STT | transcribed **with a mixed-speaker badge** |
| `insufficientSpeech` | voiced duration below VAD minimum | keep for STT (fail-open) | transcribed; flagged low-confidence |

Fail-open principle: when in doubt, **transcribe and surface**, never silently hide ATC. Calibration of the two thresholds against the replay corpus is a deliverable of the implementation cycle and must be recorded back into this doc when measured. No threshold is asserted correct until then.

## 4. Future hardware validation matrix (no purchase required now)

This matrix is staged so the simulator/replay lanes carry the load today and the hardware lanes are filled opportunistically with gear Andrei already has or borrows — consistent with ADR 0004 and ADR 0005.

| Lane | Source | Requires purchase? | Validates | Status |
|---|---|---|---|---|
| Replay (CI) | committed fixtures | no | decisions, routing, offline guarantee | primary — must pass |
| Simulator smoke | iPhone 17 Pro / iOS 26.4 sim, file-injected audio | no | UX states, download/cancel/retry, badge invariance | required before TestFlight |
| Built-in mic, on-hand device | iPhone built-in mic | no (device on hand) | live VAD/enrollment ergonomics | opportunistic |
| Wired intercom / cable path | existing cable + headset | no (use existing gear; ADR 0004) | real cockpit SNR, PTT leakage | deferred, hardware-gated |
| In-aircraft | real cockpit | no (field, not purchased) | end-to-end realism | deferred (ADR 0005) |

No lane in this matrix requires Andrei to buy hardware. The wired and in-aircraft lanes are explicitly deferred and are **not** prerequisites for the offline + simulator gates.

## 5. Evidence checklist

Simulator / CI lane (must be green before the feature ships behind its toggle):

- [ ] Network-deny integration test green (§1) on iPhone 17 Pro / iOS 26.4 sim.
- [ ] Missing-pack-throws test green (no silent auto-download).
- [ ] Download-phase boundary test green (egress only during `downloading`, one-directional).
- [ ] Source-override (`baseURL`) test green.
- [ ] Privacy-badge invariance test green across all five states.
- [ ] Model-pack state-machine round-trip persistence test green (storage-protocol injected).
- [ ] Embedding dimension asserted (256) against the live backend.
- [ ] All replay fixtures (§2) produce their expected decision/routing labels.
- [ ] Threshold calibration values measured on the corpus and written back into §3.
- [ ] mac24 `xcodebuild build test` full Dspeech suite green; command + result pasted into the run note.

Physical-device lane (opportunistic; not a ship blocker for the toggled feature):

- [ ] Built-in mic enrollment smoke on an on-hand device.
- [ ] Wired-path SNR/PTT-leakage observations recorded (existing cable; deferred).

When evidence is produced, link the exact test command and result here and in the run note — assertions without pasted output do not count.
