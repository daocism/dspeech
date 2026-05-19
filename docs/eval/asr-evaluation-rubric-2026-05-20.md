# ASR evaluation rubric — adapter qualification gate

Date: 2026-05-20. Status: draft. Scope: defines the rubric only — does not score any
adapter, does not implement the harness, does not define corpus content.

## 1. Goal

This rubric is the qualifying gate every candidate ASR adapter must clear before it is
eligible for v1 inclusion. "Qualified" means the adapter scored each rubric dimension at
or above its numeric pass threshold on the frozen test partition of the evaluation corpus
(see `evaluation-corpus-spec.md`). Passing the rubric does not mandate adoption — the
adapter shortlist decision in the (sibling) `docs/adr/0007-asr-adapter-selection-draft.md`
balances qualified adapters on latency, footprint, and license. Failing the rubric
disqualifies an adapter for v1 unless an exemption ADR is written that explicitly
overrides a named dimension and its threshold.

This rubric is referenced by, and does NOT supersede, `docs/eval/asr-benchmark-plan.md`
(which frames candidates, the run protocol, and the artifact layout) or
`docs/eval/terminology-guard-spec.md` (which owns the aviation glossary and critical-phrase
list). Where this rubric duplicates a number that also appears in the benchmark plan, the
benchmark plan is authoritative for the corpus-bucket-specific WER pass bars; this rubric
is authoritative for the dimension formulas, tokenization, and statistical methodology.

## 2. Scope

In scope: ASR transcript output quality on the eval corpus, measured against human
reference transcripts produced per `evaluation-corpus-spec.md`. Latency is scored only for
the end-of-utterance → first-partial-token interval because that interval is what the
on-screen transcript UI exposes to the user.

Out of scope:

- Full cold-start latency budget — owned by `docs/ops/cold-start-latency-budget-2026-05-20.md`
  (sibling burn branch).
- Battery / thermal drain — owned by `docs/BATTERY-PROBE-PLAN.md` (sibling burn branch).
- Translation quality — owned by `docs/eval/translation-benchmark-plan.md`.
- Adapter-internal characteristics (model size, license, vendor SLA) — owned by the ADR.
- Live-mic A/B sessions — explicitly excluded by `evaluation-corpus-spec.md` anti-goals.

## 3. Scoring dimensions

Eight dimensions, each with a formula, a unit, a pass threshold, a stretch ("exceeds")
threshold, and a failure consequence. Thresholds marked `INITIAL` are calibrated against
the first pilot run before they are locked; thresholds marked `RESEARCH NEEDED` await an
external citation before they bind. Thresholds without a marker are derived directly from
`asr-benchmark-plan.md` row entries and are stable.

### 3.1 Word Error Rate (WER)

- Definition: token-level edit distance between normalized reference and normalized
  hypothesis, divided by reference token count.
- Formula: `WER = (S + D + I) / N` where `S` = substitutions, `D` = deletions,
  `I` = insertions on the minimum-edit alignment, `N` = reference token count after
  normalization.
- Edit-distance variant: Levenshtein on the token sequence (not character sequence).
  Insertions and deletions cost 1; substitutions cost 1. Ties broken left-to-right.
- Unit: dimensionless ratio, 0 ≤ WER (WER can exceed 1.0 on heavy-insertion outputs).
- Pass: ≤ 0.18 corpus-wide; exceeds: ≤ 0.10. Per-bucket pass bars (synth_pilots ≤ 0.15,
  liveatc_public_archive ≤ 0.25, accented_corpus ≤ 0.35) live in
  `asr-benchmark-plan.md` and are authoritative for those buckets.
- Failure consequence: disqualifies v1 (primary metric, no waiver).

### 3.2 Character Error Rate (CER)

- Definition: character-level Levenshtein between normalized reference and hypothesis,
  divided by reference character count. Used for short utterances (≤ 4 reference tokens)
  where WER granularity is unstable.
- Formula: `CER = (S_c + D_c + I_c) / N_c` where subscript `c` denotes character counts.
- Unit: dimensionless ratio, 0 ≤ CER.
- Pass: ≤ 0.08 on the short-utterance subset; exceeds: ≤ 0.04.
- Failure consequence: advisory — degrades final qualification score by one tier but does
  not disqualify on its own. Required to be reported even when WER passes.

### 3.3 Aviation-term recall

- Definition: fraction of utterances containing at least one term from the aviation
  glossary in `terminology-guard-spec.md` where the term appears verbatim (after
  normalization) in the hypothesis.
- Formula: `term_recall = (# ref utterances with glossary term where same term present in hyp) / (# ref utterances containing any glossary term)`.
- Match policy: strict — the normalized glossary phrase must appear contiguously in the
  normalized hypothesis. Near-misses (one-token edit distance) count as miss. Synonyms
  count only when explicitly listed in the glossary `synonyms_allowed:` list (currently
  empty).
- Unit: dimensionless ratio, 0 ≤ recall ≤ 1.
- Pass: ≥ 0.90; exceeds: ≥ 0.97.
- Failure consequence: disqualifies v1 (safety-relevant; see `terminology-guard-spec.md`).

### 3.4 Critical-phrase zero-tolerance rate

- Definition: per-clip indicator equal to 1 if the reference contains a Critical-category
  phrase (per `terminology-guard-spec.md` §"Guarded categories", rows marked Critical) and
  the hypothesis does NOT contain that phrase or a glossary-listed synonym. Aggregated as
  the fraction of corpus clips where this indicator fires.
- Formula: `critical_miss_rate = (# clips where critical_failure == 1) / (# clips with critical-category ref phrase)`.
- Unit: dimensionless ratio, 0 ≤ rate ≤ 1.
- Pass: ≤ 0.02; exceeds: 0.00.
- Failure consequence: disqualifies v1. Single-metric override of WER per
  `terminology-guard-spec.md` — any critical failure fails that clip regardless of WER.

### 3.5 Numeric-string recall (altitudes / headings / frequencies / runways / squawks)

- Definition: fraction of numeric strings extracted from the reference by the regex
  anchors in `terminology-guard-spec.md` (`altitude_fl`, `freq`, plus locally-scoped
  anchors for headings, runways, squawks) that appear verbatim in the hypothesis after
  normalization.
- Formula: `num_recall = (# matched numeric strings in hyp) / (# numeric strings in ref)`.
- Match policy: digit-for-digit. After normalization, "one zero" and "ten" are distinct
  strings; the normalization step (§4) maps both to the same canonical form, and the
  match runs on canonical form. "10" and "1 0" are also distinguishable through the
  whitespace-preservation rule below.
- Unit: dimensionless ratio.
- Pass: ≥ 0.90; exceeds: ≥ 0.98.
- Failure consequence: disqualifies v1 (numeric errors are operational-risk equivalents
  of critical-phrase misses).

### 3.6 Latency-to-first-partial

- Definition: wall-clock milliseconds from the end of utterance audio (last non-silent
  sample, detected by VAD with a 300 ms hangover) to the timestamp at which the adapter
  emits its first partial-transcript token for that utterance.
- Formula: `latency_first_partial_ms = t_first_partial - t_end_of_utterance_audio`.
- Aggregation: report p50, p90, p99 over all utterances in the test partition.
- Unit: milliseconds.
- Pass: p50 ≤ 400 ms AND p90 ≤ 700 ms AND p99 ≤ 1200 ms on iPhone 15 baseline.
- Exceeds: p50 ≤ 250 ms AND p90 ≤ 500 ms AND p99 ≤ 900 ms.
- Failure consequence: disqualifies v1 for the on-device primary slot; an adapter that
  fails latency but passes accuracy may stay as a "background re-decode" candidate.
- Note: the cold-start component (first-utterance-after-launch) is owned by the cold-start
  latency budget doc — this rubric measures steady-state only, starting from the second
  utterance in each session.

### 3.7 Confidence calibration (Expected Calibration Error, ECE)

- Definition: bin the adapter's per-token confidence scores into 10 equal-width bins on
  `[0.0, 1.0]`; for each bin compute empirical accuracy (fraction of tokens in bin that
  match reference) and mean confidence; ECE is the weighted absolute gap.
- Formula: `ECE = Σ_b (n_b / N) · |acc_b - conf_b|` summed over bins `b`, where `n_b` is
  the bin token count and `N` is total tokens.
- Unit: dimensionless ratio, 0 ≤ ECE ≤ 1.
- Pass: ≤ 0.08; exceeds: ≤ 0.04.
- Failure consequence: advisory — degrades qualification tier by one but does not
  disqualify. Reason: the runtime UI uses confidence to underline low-confidence tokens
  (per `terminology-guard-spec.md` §"Runtime use"); a miscalibrated adapter still
  functions but produces worse UX.
- `RESEARCH NEEDED — confirm Apple Speech (SFSpeechRecognizer / SpeechAnalyzer) exposes
  per-token confidence; if not, this dimension is N/A for that adapter and the adapter
  must pass a higher WER bar (≤ 0.15) instead, set in the ADR.`

### 3.8 Call-sign exact-match

- Definition: fraction of reference call signs (extracted by the
  `terminology-guard-spec.md` `callsign` regex anchor) that appear verbatim in the
  hypothesis after normalization.
- Formula: `callsign_acc = (# matched call signs) / (# ref call signs)`.
- Unit: dimensionless ratio.
- Pass: ≥ 0.85 (matches `asr-benchmark-plan.md` row); exceeds: ≥ 0.95.
- Failure consequence: disqualifies v1 (a wrong call sign in the transcript is the single
  most user-visible safety-relevant error).

## 4. Tokenization rules

Identical normalization applied to reference and hypothesis before any dimension is
computed. Copy-pasteable:

1. Convert to Unicode NFC.
2. Lowercase using `str.lower()` (ASCII; the corpus is English-only per
   `evaluation-corpus-spec.md`).
3. Strip punctuation `[,!?;:"'`(){}\[\]]` — but retain `.` only when it appears between
   two digits (decimal point inside a frequency like `121.5`); elsewhere strip `.` too.
4. Direction: **digit numerals → digit words**. Pinned. Rationale (2 sentences): the
   evaluation corpus references are stored in ICAO spelled-out form (`flight level three
   five zero`) per `evaluation-corpus-spec.md` §"Reference transcript convention", so
   hypotheses must be lifted to the same surface to align. The inverse direction (words
   → numerals) would require a non-trivial number parser and would lose the digit-by-digit
   semantics that aviation phraseology depends on.
5. Aviation-specific digit and word normalizations (canonical → variants collapsed to
   canonical, applied to both ref and hyp):

| Variant tokens | Canonical token |
|---|---|
| `niner`, `9`, `nine` | `nine` |
| `tree`, `3`, `three` | `three` |
| `fife`, `5`, `five` | `five` |
| `0`, `zero`, `oh` | `zero` |
| `1`, `one`, `wun` | `one` |
| `2`, `two`, `too` | `two` |
| `4`, `four`, `fower` | `four` |
| `6`, `six` | `six` |
| `7`, `seven` | `seven` |
| `8`, `eight`, `ait` | `eight` |
| `decimal`, `point`, `dot` (between digits) | `decimal` |
| `hundred`, `hundered` | `hundred` |
| `thousand`, `thousant` | `thousand` |

6. Collapse all runs of whitespace to a single space; strip leading/trailing space.
7. Drop non-speech tags `[static]`, `[clipped]`, `[unintelligible]` from both ref and
   hyp before tokenization (per `asr-benchmark-plan.md` normalization step 5).
8. Unknown-token policy: any hypothesis token not on the normalization table is kept
   verbatim. We never silently substitute toward the reference; that would mask adapter
   errors.

Implementation lives in `eval/tools/normalize_transcript.py` (to be authored when the
harness lands — out of scope here).

## 5. Aviation-term list (input, not defined here)

The glossary of aviation phrases and tokens used by §3.3 and §3.4 lives in
`eval/glossary/aviation.en.yaml` per `terminology-guard-spec.md`. That file is an INPUT to
this rubric, not defined here. The glossary version is recorded in the eval report
artifact (see §8) and is versioned in lockstep with the corpus (`eval/corpus/VERSION`):
glossary `version:` and corpus `VERSION` use the same `YYYY-MM-DD.N` format and bump
together when either changes.

## 6. Sample size and statistical significance

- Minimum utterances per corpus source bucket: ≥ 200. Buckets enumerated in
  `evaluation-corpus-spec.md` §"Source buckets".
- Minimum total test-partition corpus: ≥ 1000 utterances across all buckets.
- Confidence-interval method: nonparametric bootstrap over utterances. Number of
  resamples: 1000. Report 95% CI (2.5th and 97.5th percentile of the resampled metric).
- Significance threshold for adapter-A-vs-B comparison on the primary metric (WER): the
  95% CIs of the two adapters' corpus-level WER do not overlap. Overlapping CIs → no
  declared winner on accuracy; defer to latency / footprint per the ADR.
- Why these numbers (3 sentences): 200 per bucket gives bootstrap-CI half-widths under
  ±0.03 on WER for adapters near the pass threshold, which is small enough to discriminate
  between candidates separated by ≥ 0.05 absolute WER. 1000 total utterances keeps the
  test partition runnable on a single iPhone in under one hour, which is the per-run
  budget set by `audio-input-matrix.md` benchmark-coverage notes. The 1000-resample
  bootstrap is standard for ML eval and is what `sacrebleu` defaults to for translation;
  using the same count keeps the ASR and MT rubrics symmetric.
- `RESEARCH NEEDED — confirm bootstrap CI math against a citable reference (Efron &
  Tibshirani 1993 or a more recent NLP-eval source) before locking the 1000-resample
  count.`

## 7. Pass thresholds for v1 qualification

| Dimension | Pass threshold | Exceeds threshold | Source | Failure consequence |
|---|---|---|---|---|
| WER (corpus-wide) | ≤ 0.18 | ≤ 0.10 | derived from `asr-benchmark-plan.md` weighted by bucket sizes | disqualifies v1 |
| WER (synth_pilots bucket) | ≤ 0.15 | ≤ 0.08 | `asr-benchmark-plan.md` row | disqualifies v1 |
| WER (liveatc_public_archive) | ≤ 0.25 | ≤ 0.15 | `asr-benchmark-plan.md` row | disqualifies v1 |
| WER (accented_corpus) | ≤ 0.35 | ≤ 0.25 | `asr-benchmark-plan.md` row | disqualifies v1 |
| CER (short-utterance subset) | ≤ 0.08 | ≤ 0.04 | INITIAL — calibrate against pilot run before locking | advisory |
| Aviation-term recall | ≥ 0.90 | ≥ 0.97 | INITIAL — calibrate against pilot run before locking | disqualifies v1 |
| Critical-phrase miss rate | ≤ 0.02 | 0.00 | `terminology-guard-spec.md` ("any critical failure → engine fails the clip") | disqualifies v1 |
| Numeric-string recall | ≥ 0.90 | ≥ 0.98 | `asr-benchmark-plan.md` number-string accuracy row | disqualifies v1 |
| Call-sign exact-match | ≥ 0.85 | ≥ 0.95 | `asr-benchmark-plan.md` call-sign accuracy row | disqualifies v1 |
| Latency-to-first-partial p50 | ≤ 400 ms | ≤ 250 ms | INITIAL — derived from PRD F1 readability requirement | disqualifies primary slot |
| Latency-to-first-partial p90 | ≤ 700 ms | ≤ 500 ms | INITIAL — calibrate against pilot run before locking | disqualifies primary slot |
| Latency-to-first-partial p99 | ≤ 1200 ms | ≤ 900 ms | INITIAL — calibrate against pilot run before locking | disqualifies primary slot |
| Expected Calibration Error | ≤ 0.08 | ≤ 0.04 | INITIAL — calibrate against pilot run before locking | advisory |

## 8. Reporting format

Every adapter run produces one artifact named `eval-report-<adapter>-<sha>.md` under
`eval/runs/<engine>_<corpus_version>_<YYYY-MM-DD>/` (path consistent with
`asr-benchmark-plan.md` §"Run protocol"). The report contains: adapter identity (engine
name, model id, model version, decode parameters); corpus version `YYYY-MM-DD.N`;
glossary version `YYYY-MM-DD.N`; the device under test (iPhone model + iOS version); one
row per dimension with point estimate and 95% CI; a pass/fail verdict per dimension and
an overall verdict (qualified / disqualified / qualified-with-advisory); and the
verbatim text of the 20 worst-WER utterances (reference + hypothesis, no audio attached
— audio is excluded for license posture per `evaluation-corpus-spec.md` §"Privacy /
legal posture").

## 9. Adversarial categories

The test corpus MUST stress-test each of the following failure modes. Each adversarial
category has at least 100 utterances allocated; the per-bucket minimum (§6) applies on top.

- Heavy ambient cockpit noise — clips with SNR in the 5–10 dB range per
  `audio-input-matrix.md` "Built-in mic in loud cockpit" row.
- Multiple speakers per utterance (controller + readback in the same clip without a
  clean break).
- Non-native-English controllers, accent set restricted to the ten accents enumerated in
  `evaluation-corpus-spec.md` `accented_corpus` row (RU, UA, DE, FR, ES, CN, IN, JP, BR,
  IT). Per-accent minimum: ≥ 30 utterances each.
- Rapid number sequences (frequencies, headings, altitudes spoken in quick succession
  with ≤ 200 ms inter-token gap).
- Single-syllable corrections and tags (`negative`, `negative`, `correction`,
  `disregard`, `affirm`).
- Clipped / static segments containing `[clipped]` or `[static]` non-speech tags — these
  tags are dropped during normalization per §4, but the surrounding speech is still
  scored.

Per CLAUDE.md project rule §8, CIS-region speaker categories are excluded from this
corpus. The exclusion is enforced at the corpus-spec level (see
`evaluation-corpus-spec.md`'s accent list) and is restated here so a reader of this
rubric in isolation does not assume the rubric itself adds Russian-speaker or
Belarusian-speaker buckets.

## 10. Reproducibility

The rubric is computable by hand from `(reference, hypothesis)` text pairs and the
adapter's emitted per-token confidence array. No proprietary tooling is required. Every
formula in §3 reduces to either Levenshtein distance (§3.1, §3.2, §3.8) or
set-intersection counting (§3.3, §3.4, §3.5) or a 10-bin histogram (§3.7) or a wall-clock
delta (§3.6).

Optional library dependencies and the license to verify before importing:

- `jiwer` — WER/CER reference implementation. `RESEARCH NEEDED — confirm Apache-2.0
  license is compatible with our repo posture.`
- `sacrebleu` — used by the sibling MT rubric for bootstrap CI; we adopt the same
  resampling default. `RESEARCH NEEDED — confirm license.`
- No third-party tool is required to produce the rubric numbers; any divergence between
  our scoring script and one of these libraries is a bug in our script and the libraries
  are authoritative.

## 11. Out of scope

- Implementing the harness that drives ASR adapters over the corpus and produces the
  artifact described in §8.
- Choice of test-runner framework (Swift Testing vs XCTest vs Python harness).
- CI integration — whether the rubric runs on every PR or only on a release branch.
- Scoring of any specific adapter — that produces an `eval-report-<adapter>-<sha>.md`
  artifact, not a rubric edit.
- Cloud-adapter qualification — out of MVP scope per ADR 0002. If/when cloud adapters
  qualify, the rubric still applies but the latency dimension (§3.6) needs a network-RTT
  surcharge term added in a follow-up doc.

## 12. Open questions

1. Does Apple SFSpeechRecognizer / SpeechAnalyzer expose per-token confidence? — answer
   source: Apple Developer documentation, verified by the harness implementer when §3.7
   is wired. Falls back to the §3.7 "no confidence" branch (raised WER bar) if not.
2. Do we adopt `jiwer` and `sacrebleu` as scoring libraries or hand-roll? — answer
   source: license-review pass during harness implementation; this rubric is library-agnostic.
3. Are the INITIAL thresholds in §7 (CER 0.08, aviation-term recall 0.90, calibration
   0.08, latency p50/p90/p99) survivable on Apple Speech today, or do they need to be
   loosened before locking? — answer source: pilot run on a 100-utterance smoke subset.
4. Is the 200-utterance-per-bucket floor enough for the bootstrap CIs to discriminate
   between adapters at the latency p99 dimension (which has heavier tails)? — answer
   source: bootstrap-stability check during pilot run; raise to 400 if p99 CI half-width
   > 200 ms.
5. Should the rubric treat speaker-overlap clips as a separate bucket with its own WER
   floor, or fold them into the existing `liveatc_public_archive` and `accented_corpus`
   buckets? — answer source: Andrei decision, pending the §9 adversarial coverage audit.
6. What policy governs adapters that pass all dimensions on `synth_pilots` but fail
   `accented_corpus`? — answer source: the (sibling) ADR 0007 draft on adapter selection;
   the working assumption is "qualified for v1 with an accent-coverage advisory."

## 13. References

- ADR 0001 (`docs/adr/0001-ios-first-local-first.md`) — on-device default.
- ADR 0002 (`docs/adr/0002-privacy-local-only-default.md`) — local-only privacy posture.
- ADR 0007 (sibling burn branch `feat/asr-adapter-selection`,
  `docs/adr/0007-asr-adapter-selection-draft.md`) — adapter shortlist decision.
- `docs/eval/asr-benchmark-plan.md` — candidates, run protocol, artifact layout.
- `docs/eval/evaluation-corpus-spec.md` — corpus content and partitioning.
- `docs/eval/terminology-guard-spec.md` — aviation glossary, critical-phrase categories,
  regex anchors.
- `docs/eval/translation-benchmark-plan.md` — sibling rubric for the MT side.
- `docs/eval/audio-input-matrix.md` — SNR profile per input path.
- `docs/product/prd-ios-mvp.md` — F1 quality-bar phrasing.
