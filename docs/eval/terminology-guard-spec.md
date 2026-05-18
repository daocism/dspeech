# Terminology guard — specification

Date: 2026-05-18. Status: draft. Cross-cuts ASR + MT eval and runtime UI.

## Purpose

Aviation phraseology has a thin layer of high-stakes words/phrases where a one-token error (e.g. `cleared to land` vs `cleared to taxi`) changes the meaning catastrophically. A terminology guard is a deterministic post-processor that:

1. Detects whether each guarded term/phrase appears in the reference and the hypothesis (ASR or MT output).
2. Scores fidelity at the phrase level (not just token-level WER/BLEU).
3. Surfaces high-risk substitutions in the transcript UI (visual underline, never auto-correction).

Anchored to ICAO Doc 4444 (PANS-ATM) and FAA JO 7110.65 phraseology. (Citations to specific paragraphs deferred to the implementation PR.)

## Guarded categories

| Category | Examples | Failure cost |
|---|---|---|
| Clearance verbs | `cleared to land`, `cleared for takeoff`, `cleared to taxi`, `line up and wait`, `hold short` | Critical — confusing land vs taxi is unsafe |
| Distress / urgency | `mayday`, `pan-pan`, `emergency`, `declaring emergency` | Critical — false positives or false negatives both costly |
| Action verbs | `roger`, `wilco`, `unable`, `affirm`, `negative`, `standby`, `disregard`, `correction` | High |
| Instructional verbs | `turn left`, `turn right`, `descend`, `climb`, `maintain`, `expect`, `report`, `contact`, `monitor` | High |
| Squawk / transponder | `squawk`, `ident`, `squawk 7500` (hijack), `squawk 7600` (radio fail), `squawk 7700` (emergency) | Critical for 7500/7600/7700 |
| Call sign integrity | Airline + flight number, registration prefix | Critical |
| Numbers (altitudes/headings/freq) | `flight level three five zero`, `heading two seven zero`, `one two one decimal five` | Critical |
| Runway designators | `runway zero four left`, `runway two seven` | Critical |

## Glossary file format

```
eval/glossary/aviation.en.yaml
```

```yaml
version: 2026-05-18.1
critical_phrases:
  - phrase: "cleared to land"
    must_translate_as:
      ru: "посадка разрешена"
      es: "autorizado a aterrizar"
  - phrase: "mayday"
    must_translate_as:
      ru: "mayday"          # keep verbatim per ICAO Annex 10
      es: "mayday"
critical_tokens_keep_verbatim:
  - mayday
  - pan-pan
  - squawk
  - wilco
  - roger
  - unable
  - affirm
  - negative
regex_anchors:
  callsign: "(?i)([a-z]{3})\\s?(\\d{1,4})(\\s?heavy)?"
  altitude_fl: "flight level (one|two|three|four|five|six|seven|eight|niner|nine) ((one|two|three|four|five|six|seven|eight|niner|nine|zero)\\s?){1,2}"
  freq: "(one|two|three) ((one|two|three|four|five|six|seven|eight|niner|nine|zero)\\s?){1,2}decimal ((one|two|three|four|five|six|seven|eight|niner|nine|zero)\\s?){1,3}"
```

Date format in `version`: `YYYY-MM-DD.N` matching corpus version style.

## Guard scoring

For ASR hypothesis vs reference:

```
phrase_recall = (# guarded phrases correctly present in hyp) / (# in ref)
phrase_precision = (# correctly present) / (# in hyp)
phrase_f1 = harmonic mean
critical_failure = ref contains a Critical-category phrase AND hyp does not contain a synonym-allowed match
```

Critical failures are reported separately. **Any critical failure → engine fails the benchmark for that clip**, regardless of WER.

## Runtime use (UI)

- Background pass over each finalized segment: regex/glossary match.
- Matched guarded phrases get visual emphasis (bold, no color — color is for confidence).
- If a Critical-category phrase is detected with low ASR confidence, show a small `?` glyph at end of line — never auto-correct.
- Translation: when toggled ON, run the guard on the translated text against `must_translate_as` rules; if violated, show original English in italic inline.

## What this is NOT

- Not auto-correction. We never silently change what the engine produced.
- Not a safety system. Dspeech is receive-only; final responsibility is the pilot's. Wording in App Store + onboarding must match.

## Open questions (Andrei action required)

- Approve glossary v1 (Andrei to review phrase list).
- Confirm policy: which guarded English terms must stay verbatim in non-English UI translations.

## References

- ICAO Doc 4444 (PANS-ATM), Annex 10 vol II.
- `evaluation-corpus-spec.md`, `asr-benchmark-plan.md`, `translation-benchmark-plan.md`.
