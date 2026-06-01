# Run note — 2026-06-01 — real FluidAudio speaker model on real ATC audio

ADR 0008's evidence lane, run with the **real** FluidAudio CoreML stack (not the
synthetic amplitude classifier used by the `DspeechReplayKit` threshold gate). Tool:
`Dspeech/Tools/SpeakerEval` (host-only SPM, FluidAudio 0.14.7 pinned).

## How to run

```bash
cd Dspeech/Tools/SpeakerEval
swift run SpeakerEval            # defaults to the committed real-ATC fixtures
swift run SpeakerEval <wav> …    # or explicit 16 kHz mono WAVs
```

First run downloads `pyannote_segmentation.mlmodelc` + `wespeaker_v2.mlmodelc` from
HuggingFace (13 files) into `~/Library/Application Support/FluidAudio/Models/` and
compiles them for the Neural Engine. Host: macOS 26.4.1, Apple M4 Pro.

## Result (committed fixtures = the two desktop ATC clips)

| Clip | Length | Diarized speakers | Segment | Quality | Embedding |
|---|---|---|---|---|---|
| `atc-real-img2549.wav` | 4.09 s | **1** (speaker 1) | 0.000–3.831 s | 0.137 | 256-dim |
| `atc-real-img2551.wav` | 8.31 s | **1** (speaker 2) | 0.034–7.054 s | 0.204 | 256-dim |

- **Cross-clip whole-embedding cosine distance = 0.696** (0 = identical voice, 2 =
  opposite). FluidAudio's clusterer also created a *new* speaker for the second clip
  (distance-to-closest 0.92), i.e. it treats the two clips as **distinct controller
  voices**.
- WeSpeaker embedding dimension is **256**, matching
  `FluidAudioSpeakerIdentifier.weSpeakerEmbeddingDimension` and the ADR 0008 gate.

## Interpretation (honest)

- **The real backend works end-to-end on real ATC audio**: download → CoreML compile →
  VAD/segmentation → 256-dim WeSpeaker embeddings → clustering, all on-device-class
  hardware. This is the substitution ADR 0007/0008 anticipated, exercised for real.
- **Quality scores are low (0.137 / 0.204)** — these are short, band-limited, noisy
  radio clips. Embeddings from such audio are not high-confidence.
- **Pilot-vs-controller labeling is NOT established here, by design.** Each clip is a
  single speaker; there is no enrolled *pilot* reference voiceprint for these clips and
  no human segment labels, so a trustworthy pilot-discard precision/recall on this audio
  is not computable. The enroll→classify demo (enrolling one diarized segment, scoring
  the clips) is unstable at these qualities — which is exactly why ADR 0008 keeps discard
  gated behind real enrollment + threshold tuning + a labeled eval before production.

## What this closes / what remains

- Closes: the "run the real model on real audio" evidence step — the FluidAudio path is
  proven operational and produces correctly-dimensioned embeddings on the actual clips.
- Remains (pre-production, needs data we do not have): enrollment reference voiceprints
  for known pilots, human-labeled pilot/controller segments on real cockpit audio, and
  threshold calibration (`pilotMatchThreshold`, `minQuality`) against that labeled set.
  The synthetic-fixture threshold gate (`eval-threshold.json`, now CI-gated) remains the
  regression guard for the routing logic; this lane is the acoustic-model evidence.
