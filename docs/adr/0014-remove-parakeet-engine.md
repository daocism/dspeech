# ADR 0014 — Remove the Parakeet EOU engine (supersedes ADR 0012)

Date: 2026-07-02
Status: accepted (owner decision, same day as the first real evaluation)
Relates: ADR 0012 (superseded), ADR 0009/0011 (unchanged and now the whole roster),
ADR 0007/0008 (FluidAudio stays for the speaker/diarization pack),
`docs/run-notes/2026-07-02-parakeet-host-eval.md` (the evidence run, commit abb8961)

## Context

ADR 0012 shipped Parakeet EOU 120M (FluidAudio streaming) as a third, English-only,
user-selectable engine. It landed fully wired — installer with per-file SHA-256,
settings section, locale gating, green unit tests — but a review-hardening audit
established that the real model had never produced a single transcript on any target.

The first real evaluation (host tier, production adapter, pinned pack, EN cockpit
corpus) measured:

| category | Parakeet WER / classification | WhisperKit reference |
|---|---|---|
| clean   | 0.760 / 67% | 0.176 / 92% |
| radio   | 0.562 / 42% | 0.213 / 100% |
| overlap | 1.000 / —   | reported only |

Failure modes are disqualifying for the domain, not marginal: callsign corruption
("Three Alpha Bravo" → "three alpha brahmo"), digit strings verbalized as cardinals
("one two three" → "one hundred and twenty three"), content substitutions in
clearances, two clips with empty output. A LibriSpeech-trained model without
ATC-domain adaptation, running with confidence 0 on every segment (no per-segment
confidence in the streaming API), offers pilots a selectable path that is materially
worse than both alternatives while looking equally legitimate in Settings.

## Decision

1. **Remove the Parakeet engine from the product entirely**: engine, streaming
   adapter, installer, settings surface, engine-choice case, CLI arm, eval arm,
   policy contracts, localization keys.
2. **The roster is Apple `SFSpeechRecognizer` (default) + WhisperKit (selectable,
   multilingual)** — exactly ADR 0009/0011.
3. **FluidAudio remains a dependency** for the speaker/diarization pack (ADR
   0007/0008). Only the ASR usage is removed.
4. Persisted `engineChoice == "parakeet"` decodes to `.apple` via the existing
   unknown-value fallback (pinned by a regression test). No field installs of the
   model pack exist (the app has never shipped), so no on-device cleanup path is
   required.
5. The evaluation tooling is preserved in history (commit abb8961) and the run-note
   stays as the canonical evidence.

## Re-entry criteria (if a streaming engine is ever reconsidered)

A candidate must, on the same EN cockpit corpus via the same harness, meet the
WhisperKit-tuned gates (clean WER ≤ 0.20, radio ≤ 0.55, clean classification ≥ 80%),
provide a real per-segment confidence, and then still pass the in-app device
verification lane before becoming selectable. Wiring-first-measure-later is the
anti-pattern this ADR exists to prevent.
