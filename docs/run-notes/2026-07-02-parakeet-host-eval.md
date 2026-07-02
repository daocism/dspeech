# Parakeet EOU 120M — first host transcript + eval (2026-07-02)

Branch: `fix/review-hardening-20260702`. Author: audio/ML review-hardening.

## What changed (why this note exists)

Parakeet EOU (the third ASR engine — FluidAudio `StreamingEouAsrManager`, 120M CoreML) had
**never produced a transcript on any target**: no CLI arm, no eval, no device run. This closes the
**host tier**: the real pinned model now runs on macOS through the *production* adapter and is
measured against the controlled EN voice corpus. Device (ANE) + the in-app live path remain
unproven — see Caveats.

## How it runs

New `parakeet` arm in the ReplayKit CLI drives the SAME production code the app uses:
`SystemParakeetStreamingAdapter` (over `FluidAudio.StreamingEouAsrManager`), fed in 0.5s blocks with
`processBufferedAudio()` after each, mirroring `ParakeetLiveTranscriptionEngine`:
partial callback = ghost text, EOU callback finalizes a segment, **`reset()` after every EOU**
(FluidAudio latches `eouDetected` + accumulates tokens across the whole session — without reset
exactly one EOU fires per clip). 2s of trailing silence is appended to force the 1280ms EOU debounce
for the final utterance (a real mic sees that silence; the model still had to decode the words).

CLI usage (English-only; enforced — a non-`en` locale fails fast with a clear message):

```
swift run --package-path Dspeech/Tools/ReplayKit dspeech-replay transcribe \
  --audio <wav> --locale en --callsign N123AB --engine parakeet [--model-dir <160ms-dir>]
```

Full eval:

```
python3 scripts/testdata/run-asr-eval.py --audio-dir tmp/voice-corpus --engine parakeet
```

## Model acquisition (supply-chain pinned)

On first run the CLI downloads the pinned pack — `FluidInference/parakeet-realtime-eou-120m-coreml`
rev `40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355`, the 16 files of the `160ms` variant — into
`~/.cache/dspeech-parakeet/parakeet-realtime-eou-120m-coreml/160ms/`, and **verifies each file's
SHA-256 against `ParakeetModelInstaller.expectedModelFiles`** (the same manifest + pinned-revision
URL builder the on-device installer uses — reused verbatim, zero drift, ADR-0012). A mismatch throws
(never fail-open). A `.dspeech-verified-<rev>` sentinel skips re-hashing 220MB on the 26 eval
invocations. `--model-dir` overrides for a pre-staged bundle.

Provisioning verified live: `parakeet: pinned pack verified (rev 40a23f4c…)`.

## Sample real transcripts (reference → Parakeet)

| clip | reference | Parakeet output |
|---|---|---|
| disp-clearance (clean) | November One Two Three Alpha Bravo, cleared for takeoff, runway two seven | «november one hundred and twenty three alpha bravo play at fortekov runway two seven» |
| disp-contact-tower-radio | Three Alpha Bravo, contact tower one one eight decimal seven | «three alpha brahmo contact tower one one eight decimal seven» |
| pilot-mayday-radio | (mayday) November One Two Three Alpha Bravo engine failure | «november one two three alpha bravo engine failure» |

Qualitative read: intelligible on some clips but with heavy ATC-specific errors — digit strings
verbalized as cardinals ("one two three" → "one hundred and twenty three"), call-sign corruption
("Three Alpha Bravo" → "real fabra" / "three alphaboke"), and content substitutions
("cleared for takeoff" → "play at fortekov"). The model is LibriSpeech-trained; ATC phraseology +
synthetic TTS voices are out of its domain. Two clips produced empty output (no EOU / no tokens).

## Metrics (26 items; deterministic across re-runs)

| category | Parakeet avg WER | Parakeet classification | WhisperKit reference |
|---|---|---|---|
| clean   | 0.760 | 8/12 (67%) | 0.176 WER / 92% |
| radio   | 0.562 | 5/12 (42%) | 0.213 WER / 100% |
| overlap | 1.000 | 2/2 (100%) | (reported only) |

Parakeet is **materially worse** than WhisperKit on this corpus across every category.

## Threshold decision (WhisperKit gates kept intact)

The `voice-corpus.json` thresholds (clean WER ≤ 0.20, radio ≤ 0.55, clean class ≥ 80%) are
**WhisperKit-tuned**. Parakeet is a different model and misses all three. Per the mission the gates
were **not lowered**; instead `run-asr-eval.py` now gates **only** `whisperkit`/`apple` and treats
`parakeet` as **reported, never gated** (explicit per-engine table + comment in the script). Result:
`--engine parakeet` prints the numbers and the deltas it would miss, then exits **0** (REPORTED,
ungated). WhisperKit/apple pass/fail behavior is unchanged.

## atc-runs.log.jsonl — deliberately NOT appended

`scripts/testdata/atc-runs.log.jsonl` is a **typed, single-consumer** speaker-eval log written by
`run-atc-eval.py`. Its reader hard-requires a `seed` key on every line
(`run-atc-eval.py:230 next_seed()` does `json.loads(x)["seed"]`) and uses those seeds for rotation.
A Parakeet **ASR-WER** record has no honest place in that speaker-diarization schema: omitting `seed`
would `KeyError` and break the speaker harness; inventing one would pollute its seed-rotation pool.
Appending there would be a regression to a working consumer, so the honest home for these numbers is
this run-note. (If a shared multi-kind ASR log is wanted later, add a `kind` discriminator + a filter
at `next_seed()` — a separate change.)

## Caveats

- **Host ≠ device.** These numbers are macOS CPU/GPU CoreML, not the on-device ANE. WER can differ on
  ANE; latency certainly does.
- **In-app live path still unproven on device.** This exercises the adapter + FluidAudio decode +
  EOU + reset contract end-to-end, but not real mic capture, `LiveAudioCaptureConduit`, or the ANE.
- **Corpus is synthetic TTS**, not real human ATC — a known-adverse domain for a LibriSpeech model;
  real ATC could differ in either direction.
- The eval invokes the CLI fresh per clip (CoreML load ≈1.2s each). Deterministic across re-runs.
