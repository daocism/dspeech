# Evaluation corpus — specification

Date: 2026-05-18. Status: draft, drives all downstream benchmarks.

## Purpose

A reproducible audio + reference-transcript corpus used to score every ASR adapter and every MT adapter against the same input. Required by ADR 0001 ("reproducible evaluation") and the no-hardware-purchase constraint of ADR 0004 (we replay files instead of flying).

## Anti-goals

- No live-mic A/B sessions as the primary benchmark. Live mic is for unit smoke only.
- No corpus we are not legally allowed to redistribute or store. See `regulatory-privacy-memo.md`.

## Corpus layout

```
eval/corpus/
  manifest.jsonl                # one row per clip
  audio/<clip_id>.wav           # 16 kHz mono PCM, 16-bit
  refs/<clip_id>.txt            # human reference transcript (ICAO phraseology preserved)
  refs/<clip_id>.json           # optional token-level alignment
  metadata/sources.md           # provenance per source bucket
  VERSION                       # YYYY-MM-DD.N corpus version
```

Audio format is fixed: **16 kHz mono PCM 16-bit**. Conversion via `eval/tools/normalize.py` (to be authored when corpus lands).

## `manifest.jsonl` schema

One JSON object per line. Synthetic example:

```json
{
  "clip_id": "synth_kjfk_twr_000001",
  "source_bucket": "synth_pilots",
  "audio_path": "audio/synth_kjfk_twr_000001.wav",
  "ref_path": "refs/synth_kjfk_twr_000001.txt",
  "duration_s": 12.4,
  "language": "en",
  "facility": "TWR",
  "accent_tag": "us-native",
  "snr_db_est": 14,
  "phraseology_density": "high",
  "license": "internal-eval-only",
  "redistribute": false,
  "added": "2026-05-18"
}
```

Required: `clip_id`, `audio_path`, `ref_path`, `duration_s`, `language`, `source_bucket`, `license`, `redistribute`, `added`. Date format `YYYY-MM-DD`. Optional: the rest.

## Source buckets (target composition, MVP)

| Bucket | Provenance | Target hours | Redistribute? | Notes |
|---|---|---|---|---|
| `liveatc_public_archive` | Public LiveATC.net archives (US towers/approach) | 6 h | No | Fair-use eval only; reference transcripts ours. |
| `youtube_atc_compilations` | Public YT channels where audio is downloadable | 4 h | No | Same fair-use posture. |
| `andrei_sim_recordings` | Andrei's own MSFS / X-Plane VATSIM sessions, with consent | 4 h | Yes | Project-internal redistribution allowed. |
| `synth_pilots` | TTS-generated readbacks from ICAO Doc 4444 phraseology + cockpit-noise SFX | 4 h | Yes | Cheap to expand; phraseology coverage. |
| `accented_corpus` | Non-native English (RU/UA/DE/FR/ES/CN/IN/JP/BR/IT accents) | 4 h | Partial | Accent robustness; tag `accent_tag`. |

Target total: **≈ 22 h**, split into fixed **dev / test** partition (80 / 20). Test partition frozen and never tuned against.

## Reference transcript convention

- English speech transcribed in **ICAO phraseology canonical form**:
  - Call signs spelled out: `delta four five seven heavy` not `DL 457H`.
  - Altitudes: `flight level three five zero` / `eight thousand`.
  - Frequencies: `one two one decimal five`.
  - Numbers spoken as ATC says them (`niner` allowed; `tree`/`fife` allowed where actually spoken).
- Punctuation: minimal; only sentence-end periods. No commas inside readbacks.
- Speaker prefixes optional, format `[ATC]` / `[ACFT]` if known.
- Non-speech tags: `[static]`, `[clipped]`, `[unintelligible]`. Excluded from WER scoring (see `asr-benchmark-plan.md`).

## Labeling workflow

1. Cut raw recordings into 5–30 s clips at natural radio breaks.
2. First-pass transcription: Apple Speech or Whisper-large as draft.
3. Human correction by Andrei or a contracted ATC-literate reviewer (mandatory).
4. QA pass: regex-check all call signs/altitudes spelled out, no digits.

## Versioning

- Corpus version stored in `eval/corpus/VERSION` as `YYYY-MM-DD.N`. Bump on any clip add/remove/edit.
- Benchmark runs record the corpus version in their results JSON.
- Test partition split deterministic from `clip_id` SHA-1 (last hex char in `{0,1,2,3}` → test). Documented in `eval/tools/split.py`.

## Privacy / legal posture

- Real-world third-party-voice audio stored in a private S3 bucket Andrei controls or an encrypted external drive — Andrei chooses.
- Repo contains only `manifest.jsonl`, reference text, and a small (≤ 5 min) **synthetic** smoke subset for CI.
- See `regulatory-privacy-memo.md` for full posture.

## Open questions (Andrei action required)

- Choose corpus storage backend (S3 / NAS / encrypted external drive).
- Decide whether to contract a part-time aviation-literate transcriber, and budget if yes.
- Approve listing of LiveATC/YouTube sources as fair-use eval material (US/EU/AU IP-law boundary).

## References

- ADR 0001 (reproducible evaluation).
- `asr-benchmark-plan.md`, `translation-benchmark-plan.md`, `audio-input-matrix.md`, `terminology-guard-spec.md`, `regulatory-privacy-memo.md`.
