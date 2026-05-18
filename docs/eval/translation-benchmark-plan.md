# Translation (MT) benchmark plan

Date: 2026-05-18. Status: draft. Drives translation adapter choice for `prd-ios-mvp.md` (translation toggle).

## Question

Which on-device translation engine is good enough to render aviation/ATC English readbacks into the user's target language (priorities: RU, UA, ES, FR, DE, PT-BR, IT, JA, ZH, HI), with low enough latency to keep up with live ASR?

## Candidates (MVP shortlist)

| Engine | Type | Notes |
|---|---|---|
| Apple Translation framework (iOS 26, on-device packs) | Apple-native | First-party; language coverage limited; verify offline-pack availability per pair. |
| NLLB-200 distilled (600M) → CoreML int8 packs | Open | Strong multilingual; pack size 200–400 MB per language hub; bundle on-demand. |
| MADLAD-400 3B distilled (if a viable iOS-deployable distill exists) | Open | Better quality ceiling but heavier; benchmark on iPhone 15 Pro only. |

Cloud MT (DeepL API, Google Translate API, GPT-4o) is **out of MVP** — see `cloud-fallback-matrix.md`.

## Inputs

Subset of `evaluation-corpus-spec.md` where reference English transcripts exist. Each clip's reference text is translated by:

- Two independent professional human translators per target language (gold).
- Each candidate engine produces a hypothesis.

If pro-translator budget is unavailable initially, bootstrap with a single bilingual-speaker round (Andrei for RU/UA) and tag the gold as `single-rater`.

## Metrics

| Metric | Formula | Pass bar (MVP) |
|---|---|---|
| **BLEU-4** | corpus-BLEU (sacrebleu, default tokenization) | ≥ 35 on EN→RU, ≥ 30 on EN→{UA,DE,FR,ES,PT-BR,IT} |
| **chrF++** | char-n-gram F-score | ≥ 55 |
| **COMET-22** (`Unbabel/wmt22-comet-da`) | learned reference-based metric, 0–1 | ≥ 0.80 on aviation subset |
| **Call-sign preservation** | exact-match of regex-extracted call signs through translation | ≥ 0.98 |
| **Number/unit preservation** | altitudes/headings/freqs preserved digit-for-digit | ≥ 0.98 |
| **Latency p95** | per-segment translation wall time on iPhone 15 | ≤ 400 ms |
| **Pack size** | MB on disk per language pair | reported, target ≤ 500 MB per pair |

COMET runs on a Mac (server-side eval), not on-device.

## Aviation-specific guards

- All hypotheses pass through `terminology-guard-spec.md` checks; failures are weighted into a separate "terminology fidelity" score.
- Specific phrase tests: `cleared to land`, `go around`, `mayday`, `pan-pan`, `squawk`, `wilco`, `roger`, `unable`. These MUST be preserved as English in target languages where the standard practice is to keep the phrase verbatim (per ICAO Annex 10). Glossary in `terminology-guard-spec.md`.

## Run protocol

```
eval/mt_runs/<engine>_<lang_pair>_<YYYY-MM-DD>/
  config.json
  per_seg.jsonl     # {seg_id, src, ref, hyp, bleu, chrf, comet, callsign_ok, numbers_ok, latency_ms}
  summary.json
```

Synthetic JSONL example:

```json
{"seg_id":"synth_kjfk_twr_000001#1","src":"delta four five seven heavy turn right heading two seven zero","ref":"дельта четыреста пятьдесят семь хэви правый разворот курс два семь ноль","hyp":"дельта четыреста пятьдесят семь хэви правый разворот курс два семь ноль","bleu":100.0,"chrf":98.4,"comet":0.94,"callsign_ok":true,"numbers_ok":true,"latency_ms":210}
```

## Decision gate

Engine that meets BLEU/chrF/COMET pass bars on EN→RU + at least 4 of the priority pairs, with p95 latency ≤ 400 ms, wins. Loser engines may stay in repo for fallback/manual switching.

## Open questions (Andrei action required)

- Budget call: pay pro translators for the gold set or bootstrap with self/community?
- Choose top-3 target languages to ship first (proposed: RU, EN-as-source-only, ES — confirm).
- Confirm policy on phrases that should remain English in target language.

## References

- `evaluation-corpus-spec.md`, `terminology-guard-spec.md`, `language-pack-spec.md`, `cloud-fallback-matrix.md`.
