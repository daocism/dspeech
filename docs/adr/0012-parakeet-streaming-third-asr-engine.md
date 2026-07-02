# ADR 0012 — Third ASR engine: Parakeet EOU streaming (English-only) via FluidAudio

Date: 2026-06-22
Status: SUPERSEDED by ADR 0014 (2026-07-02) — engine removed after the first real evaluation; was: accepted (landed 2026-06-23), implemented per `docs/PLAN-2026-06-22-parakeet-third-engine.md`
Relates: ADR 0009 (SFSpeechRecognizer stays), ADR 0011 (Apple default + WhisperKit selectable), ADR 0007/0008 (FluidAudio speaker pack acquisition pattern), CLAUDE.md hard rules #1/#2 (local-only, no fake AI)

## Decision

1. **Three-engine strategy.** `LiveTranscriptionEngine` gains a third implementation
   backed by **FluidAudio**'s `StreamingEouAsrManager` (Parakeet EOU 120M streaming model,
   nvidia/parakeet_realtime_eou_120m-v1, CoreML on the Apple Neural Engine).
   - **Default stays Apple `SFSpeechRecognizer`** (ADR-0009/0011 still binding).
   - **WhisperKit stays** as the multilingual selectable alternative (ADR-0011).
   - **Parakeet EOU** is a third user-selectable alternative, optimised for low-latency
     **English-only** live transcription on supported hardware.
2. **Variant**: `parakeetEou160ms` (lowest-latency 160ms chunks). 320ms/1280ms variants
   are NOT shipped initially; they trade latency for throughput in offline batch usage
   and are not a fit for cockpit live monitoring.
3. **Locale gate is mandatory**: the engine picker offers Parakeet only when the
   selected recognition locale is in the `en-*` BCP-47 family. Choosing any non-English
   locale automatically falls back to Apple or WhisperKit; Parakeet never silently runs
   on non-English audio (the model is LibriSpeech-trained; non-English audio would be
   garbage or hallucinations, violating CLAUDE.md hard rule #2).
4. **Model acquisition mirrors ADR 0007/0008**: the Parakeet pack is downloaded
   on-demand via the existing `ModelPackAcquisitionController` infrastructure, using
   a **pinned HuggingFace revision** and a **per-file SHA-256 manifest** baked into the
   app (`ParakeetModelPackInstaller`, parallel to `SpeakerModelPackInstaller`).
   FluidAudio's auto-download (`StreamingEouAsrManager.loadModels()` with no args) is
   **not used** — supply-chain pinning is non-negotiable per existing project
   precedent.
5. **Local-only after install**: model files live in
   `Application Support/FluidAudio/Models/parakeet-realtime-eou-120m-coreml/160ms/`
   (FluidAudio's expected manual-load path). After download, `StreamingEouAsrManager.loadModels(from:)`
   is invoked with the staged folder URL — no network traffic at session start.
   `ADR 0002` (local-only default) holds: zero egress during transcription.

## Why a third engine

### Empirical case (web research summary, 2026-06)

| Engine | EN-only WER (LibriSpeech) | Streaming latency | Multilingual | Hallucination on silence | iOS-ready |
|---|---|---|---|---|---|
| Apple SFSpeechRecognizer | strong, with on-device asset | true streaming partials | yes (per-locale assets) | none (silence stays silent) | yes — default |
| WhisperKit large-v3-turbo | ~baseline | batch decode per window (no partials in current adapter) | 99 languages | known whisper-class hallucinations on silence | yes — selectable |
| **Parakeet EOU 120M** | **~8-9% (160ms), ~5.73% (320ms)** | **true streaming with built-in EOU** | **English-only** | **none reported** | **yes (new)** |

Sources: `whispernotes.app/blog/parakeet-v3-default-mac-model`, `northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks`, `arunbaby.com/speech-tech/0073-whisper-vs-parakeet-asr-decision`, `macparakeet.com/blog/whisper-to-parakeet-neural-engine`.

### What Parakeet specifically buys us for cockpit ATC (English)

- **True streaming with built-in End-of-Utterance detection.** Apple has streaming
  partials; WhisperKit (in our current adapter) does not. Parakeet has BOTH partials
  AND a model-side EOU classifier — we get a known-good utterance boundary for free,
  without our `SpeechActivitySegmenter` having to guess.
- **Lower latency than WhisperKit on English** (160ms chunks vs WhisperKit's batch
  window). Closer to Apple's perceived latency, with better completeness on noisy
  audio per published benchmarks.
- **No prompt hallucinations on dead air.** A documented WhisperKit failure mode that
  matters specifically for ATC channels with frequent silence between transmissions.
- **Already in-graph: FluidAudio is a pinned dependency** (used for speaker
  diarization), so adding the Parakeet pathway adds NO new SwiftPM packages.

### Honest limitations

- **English-only.** Parakeet EOU 120M is LibriSpeech-trained. The multilingual Parakeet
  TDT v3 model exists but is **not streaming** (it's a sliding-window offline pipeline,
  not a cache-aware live decoder). Until NVIDIA/FluidAudio ships a multilingual
  streaming variant, this engine cannot serve French/German/etc. ATC.
- **No contextual biasing.** Unlike Apple's `contextualStrings` (which biases toward
  the pilot's callsign + ATC vocabulary), Parakeet has no production-ready vocabulary
  biasing path in FluidAudio's current API surface. CTC-based custom vocabulary exists
  in FluidAudio's batch path but not in `StreamingEouAsrManager`. Callsign anchoring
  in our voice-filter gate still works on the resulting text, but the recognizer
  itself doesn't know our callsign.
- **Cockpit/VHF-degraded audio is not in the training distribution.** As with Apple
  and WhisperKit, generic-model WER on real VHF radio is worse than LibriSpeech
  numbers. This must be re-validated on cockpit fixtures before any "Parakeet default"
  consideration.

## Default-engine policy is unchanged

Apple stays default. Parakeet is **selectable**, never auto-selected. The default-engine
flip criterion from ADR-0011 still applies: a new engine becomes default only when a
harness comparison on a larger fixture corpus shows it superior on BOTH quality AND live
latency, with no hallucination regressions. Parakeet adds an option; it does not change
the default policy.

## Rejected alternatives

- **NVIDIA NeMo direct integration**: no Swift CoreML path, would require building our
  own CoreML conversion pipeline. FluidAudio already did that work.
- **Bumping FluidAudio to a hypothetical multilingual streaming variant**: no such
  variant exists in the pinned 8048812 commit (only batch v3 is multilingual). Revisit
  when upstream ships one.
- **Parakeet TDT v3 multilingual batch as a "near-live" pipeline**: sliding-window
  offline transcription is incompatible with our streaming partials contract; would
  require a different LiveTranscriptionEngine subclass with batch-window semantics
  and degrade user perception of latency. Not worth the integration cost given Apple
  already serves multilingual streaming well.

## Consequences

### New code

- `Dspeech/Core/ASR/ParakeetStreamingAdapter.swift` — thin actor wrapping
  `FluidAudio.StreamingEouAsrManager` behind a project-owned `ParakeetLiveStreaming`
  protocol (parallel to `WhisperKitTranscriberAdapter`/`WhisperLiveTranscribing`).
- `Dspeech/Core/ASR/ParakeetLiveTranscriptionEngine.swift` — implements
  `LiveTranscriptionEngine`. Reuses `LiveAudioCaptureConduit` for mic capture; consumes
  buffers via `appendAudio(_:)` + `processBufferedAudio()`; emits partials from
  FluidAudio's `partialCallback` + finals on `eouCallback`. **No** separate segmenter
  needed (EOU is model-side). Voice-filter `SpeechAudioBufferGate` still applies on
  finalized segments for own-callsign / own-voice suppression.
- `Dspeech/Core/ASR/ParakeetModelPackInstaller.swift` — mirrors
  `SpeakerModelPackInstaller`: pinned HF revision, per-file SHA-256 manifest, atomic
  staging to `Application Support/FluidAudio/Models/parakeet-realtime-eou-120m-coreml/160ms/`.
- `Dspeech/Core/Settings/RecognitionSettings.swift` — extend `TranscriptionEngineChoice`
  with `.parakeet`. Storage migration is forward-only (existing `.apple`/`.whisperKit`
  values continue to load unchanged; an unknown new value falls back to `.apple`).
- Settings UI: Parakeet picker entry visible only when `localeIdentifier.hasPrefix("en")`;
  download CTA mirrors WhisperKit's existing model-install affordance.
- `LiveTranscriptionViewModel` engine-instantiation switch grows a `.parakeet` arm.

### Tests

- Adapter contract tests with a fake `FluidAudio.StreamingAsrManager` (the protocol is
  conformable from outside; the test can substitute a stub that yields scripted partials
  and EOUs). Property tests for the partial→final transition. Lifecycle tests for
  start/stop/reset, locale gate, model-not-installed failure path. Property tests for
  the locale gate (every non-`en-*` locale rejects the engine).
- Installer tests with a `FakeFileDownloader` replicating the `SpeakerModelPackInstaller`
  test infrastructure: pinned URL construction, checksum mismatch detection,
  insufficient-disk-space taxonomy, cancellation, idempotent install detection.

### Documentation & process

- `docs/ai-kb/current-context.md` gets a "Three-engine roster" paragraph after each
  wave lands.
- `docs/PLAN-2026-06-22-parakeet-third-engine.md` is the multi-commit implementation
  spec (commit-by-commit, atomic, behavior-preserving).
- `scripts/verify-primary-scenario.sh` extends to a third engine arm; the fixture
  corpus must include at least one EN cockpit clip before any user-visible release.
- A future `scripts/check-parakeet-pack-checksums.sh` (parallel to
  `scripts/check-speaker-calibration.sh`) verifies the pinned manifest against the
  real HuggingFace revision in CI.

### Non-consequences (explicitly out of scope)

- No change to Apple-default policy. No change to WhisperKit. No change to ADR 0002
  (local-only). No new SwiftPM dependencies. No StoreKit/billing surface. No region
  list change. No background-modes change.

## Safety review (CLAUDE.md hard rules)

| Rule | Check |
|---|---|
| #1 local-only default | Pass — Parakeet runs on-device after pinned download; no inference egress. |
| #2 no fake AI / fake transcription | Pass — engine wires to a real, tested upstream library; English-only gate prevents shipping a model that would produce garbage on French audio (which would BE fake transcription in effect). |
| #3 no placeholders | Pass — implementation lands across atomic commits; no engine entry ships in the picker until the installer, hash manifest, and tests are green. |
| #4 privacy badge always visible | Unchanged — privacy mode rendering is engine-agnostic. |
| #5 no hardware promises | N/A — software-only change. |
| #6 no App Store submission from CI | N/A. |
| #7 no billing/StoreKit UI | Pass — no monetisation surface touched. |
| #8 no CIS regions | Pass — engine availability is feature-level, not region-level. |
