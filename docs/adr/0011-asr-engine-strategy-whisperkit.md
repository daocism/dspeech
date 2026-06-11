# ADR 0011 — ASR engine strategy: SFSpeechRecognizer default + WhisperKit selectable

Date: 2026-06-12
Status: accepted
Relates: ADR 0009 (SFSpeechRecognizer stays), SPEC-2026-06-12 §5

## Decision

1. **Two-engine strategy.** `LiveTranscriptionEngine` gains a second implementation
   backed by **WhisperKit** (argmax-oss-swift, MIT, Swift+CoreML, pinned `exact: 1.0.0`).
   Apple `SFSpeechRecognizer` remains the DEFAULT live engine; WhisperKit is a
   user-selectable alternative in Settings (Phase B wiring).
2. **Rejected alternatives**: whisper.cpp (C++ bridging, no Swift streaming API),
   sherpa-onnx (heavier integration, no CoreML ANE path). Revisit only if WhisperKit
   fails the harness on cockpit-realistic audio.
3. **Model**: `large-v3-v20240930_626MB` (compressed, multilingual incl. fr) from
   `argmaxinc/whisperkit-coreml`. In-app download must follow the voice-pack
   acquisition pattern: explicit size/progress/delete, local-only after download,
   pinned revision + checksum (supply-chain rules). The harness uses the same model
   from `~/.cache/dspeech-whisperkit`.

## Empirical fixture comparison (harness, 2026-06-12, mac24)

`dspeech-replay transcribe --locale fr-FR` over the owner's cockpit fixtures, both
engines, same assembler+classifier (`scripts/verify-primary-scenario.sh`):

| Fixture | Apple SFSpeech (on-device fr-FR) | WhisperKit large-v3 626MB |
|---|---|---|
| atc-2549 (4.0s taxi instruction) | «Golf Oscar Armagis sept à la côte» — callsign prefix "Fox" MISSED, middle garbled | «Fox Golf Oscar, entrée 20h, ramein gauche 17, rappelez pas ça la Côte-Mittier.» — full F-GO callsign captured, instruction structure (gauche 17, rappelez) intact |
| atc-2551 (8.3s radar/hold) | «Bonjour ton radar, prévois une petite attente secteur alpha écho 1018 avec les voies descente» — "ton radar" mishears "identifié radar" | «Bonjour, identifié radar, prévois une petite attente secteur Alpha-Eco, 1018 avec les voiles en décembre.» — correct ATC phrase "identifié radar"; tail hallucinated («en décembre») |
| Callsign anchoring | --callsign GO → DISPLAYED(callSignMatch) | --callsign FGO → DISPLAYED(callSignMatch) |
| Latency model | true streaming partials (~live) | batch decode per window; no partials in current integration |
| Biasing | contextualStrings (callsign + ATC phraseology) — unique advantage | none (prompt tokens unexplored) |
| Failure mode | drops/garbled words at low SNR | whisper-class hallucination (invents plausible words) |
| Asset | per-locale dictation asset via OS | 626MB one-time download, all languages |

## Why Apple stays default

For LIVE cockpit use the decisive factors are streaming partials (pilot sees text as
ATC speaks), contextualStrings callsign biasing, and no-hallucination behavior —
a missing word is safer than an invented instruction (receive-only safety posture).
WhisperKit wins on completeness of the callsign and overall transcript quality on
recorded audio, making it the better engine for review/replay and a promising live
alternative once its streaming adapter (AudioStreamTranscriber) is validated under
cockpit latency. The default flips only when a future harness comparison on a larger
fixture corpus shows WhisperKit superior on BOTH quality and live latency without
hallucination regressions.

## Consequences

- Phase B app work: `WhisperKitLiveTranscriptionEngine` adapter, model download UX,
  Settings engine picker (default `apple`).
- The verify-primary-scenario gate runs BOTH engines on every fixture from now on.
- Fixture corpus should grow (more cockpit recordings) before any default switch.
