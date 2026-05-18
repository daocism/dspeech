# ASR benchmark plan

Date: 2026-05-18. Status: draft. Drives the ASR adapter shortlist for `prd-ios-mvp.md`.

## Question

Among on-device-capable ASR engines available on iOS 26, which one wins on aviation/ATC audio across (a) accuracy, (b) latency, (c) memory/battery cost?

## Candidates (MVP shortlist)

| Engine | Type | Notes |
|---|---|---|
| Apple Speech (SFSpeechRecognizer, on-device mode) | Apple-native | First-party, supports on-device recognition flag, Apple Neural Engine backed. |
| Apple SpeechAnalyzer (new iOS 26 streaming API) | Apple-native | Verify availability + API surface via Apple developer docs before benchmarking. |
| WhisperKit (Argmax) `large-v3-turbo` int4 | Open / CoreML | High accuracy ceiling; latency depends on chunking. |
| WhisperKit `small.en` int4 | Open / CoreML | Lower latency, mid accuracy; viable for older iPhones. |

Cloud engines (Whisper API, Deepgram, AssemblyAI) are **out of MVP scope**; one comparative run captured in `cloud-fallback-matrix.md`.

## Inputs

Corpus from `evaluation-corpus-spec.md`. Final numbers on the **test partition**; iterate on dev only.

## Metrics & pass bars

| Metric | Formula | Pass bar (MVP) |
|---|---|---|
| **WER** | `(S+D+I)/N` after normalization | ≤ 0.15 on `synth_pilots`; ≤ 0.25 on `liveatc_public_archive`; ≤ 0.35 on `accented_corpus` |
| **CER** | Char edit distance / total chars | Reported only |
| **Call-sign accuracy** | exact-match on regex-extracted call signs | ≥ 0.85 on test |
| **Number-string accuracy** | exact-match on altitudes/headings/frequencies | ≥ 0.90 |
| **Latency p50 / p95** | end-of-utterance → finalized transcript | p50 ≤ 800 ms, p95 ≤ 1500 ms on iPhone 15 |
| **First-token latency p95** | first interim token after speech start | ≤ 600 ms |
| **Peak memory** | RSS during 60-s stress | ≤ 600 MB on iPhone 15 |
| **Battery drain** | %/60 min continuous, screen off | ≤ 25% on iPhone 15 |

## Normalization (mandatory before scoring)

Apply identically to hypothesis + reference:

1. lowercase
2. strip punctuation except `.` and `,`
3. spell out digits (`350 → three five zero`)
4. expand ATC abbreviations from a fixed dict (`fl → flight level`, `kt → knots`)
5. drop non-speech tags (`[static]`, `[clipped]`, `[unintelligible]`)
6. collapse whitespace

Implementation: `eval/tools/normalize_transcript.py` (todo). Same dict drives `terminology-guard-spec.md`.

## Run protocol (artifact layout)

```
eval/runs/<engine>_<corpus_version>_<YYYY-MM-DD>/
  config.json        # engine version, model id, decode params
  per_clip.jsonl     # one row: clip_id, hyp, ref, wer, cer, latency_ms, mem_mb
  summary.json       # aggregate metrics
  hardware.json      # device id, iOS version, battery start/end
```

Per-clip JSONL synthetic example:

```json
{"clip_id":"synth_kjfk_twr_000001","hyp":"delta four five seven heavy turn right heading two seven zero","ref":"delta four five seven heavy turn right heading two seven zero","wer":0.0,"cer":0.0,"latency_ms":612,"mem_mb":312}
```

Each run reproducible from `config.json` + corpus version. Date format `YYYY-MM-DD`. On-device runs execute on a physical iPhone 15 via a small XCTest harness; simulator runs only for smoke.

## Decision gate

Engine that meets all "pass bar" metrics on `synth_pilots` + `liveatc_public_archive` AND has the lowest p95 latency wins. Tie → prefer the smaller model (battery + privacy posture). No engine passes → escalate to Andrei with the gap table.

## Open questions (Andrei action required)

- Approve LiveATC/YT clip ingestion (see corpus spec).
- Approve physical-device benchmark window on Andrei's iPhone (≈ 2 h, screen on).

## References

- `evaluation-corpus-spec.md`, `terminology-guard-spec.md`, `audio-input-matrix.md`, `cloud-fallback-matrix.md`.
