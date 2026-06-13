# W9 — Localization fill for the 32 new en-only strings

Read brief-common.md first.

## Files you own

- `Dspeech/Localizable.xcstrings` (ONLY this file)

No code, no pbxproj, no tests beyond the build.

## Task

`Dspeech/Localizable.xcstrings` has 285 strings; 32 of them carry only an `en`
localization (added by the core-semantics rebuild). Every shipped locale must be
complete — a half-localized French-ATC product is the exact "mockup" smell we are
removing. Add translations for ALL of these 10 locales to each of the 32 strings:
`de, es, fr, it, ja, ko, pt, ru, uk, zh-Hans`.

The 32 keys are exactly those whose `localizations` object currently lacks a `fr`
entry (equivalently, lacks any non-en locale — they are all missing all 10). They
cover: the no-anchor hint, filtered-transmission reason badges (Dispatcher voice,
Follow-up call, Addressed to other aircraft, etc.), the filtered-count plural, the
WhisperKit engine picker section (Recognition engine, Engine, Apple Speech,
WhisperKit), and the model install/download/delete/error states.

## How (binding)

1. Parse the JSON, find the keys missing the 10 locales, and for EACH add a
   `localizations.<locale>.stringUnit` with `state: "translated"` and the
   translated `value`, matching the EXACT shape of already-translated entries in the
   same file (look at any complete string for the structure; preserve `%lld`/`%@`
   format specifiers verbatim and in grammatically correct position per language).
2. **Terminology consistency is the priority**: this file already has 253 fully
   translated strings. Before translating, scan how the existing translations render
   the domain vocabulary in each language — "transmission", "callsign", "filter",
   "ATC/dispatcher", "recognition", "download", "model", "Apple Speech" (likely kept
   as a proper noun), "WhisperKit" (proper noun — keep as-is in every locale). Reuse
   those exact terms. Do not invent new terms where the file already established one.
3. Plurals: `%lld filtered transmissions` and `%lld filtered` — if the existing file
   uses `.variations.plural` for other counted strings, mirror that structure for the
   target languages that need plural categories (ru/uk need one/few/many/other; the
   others typically one/other). If the existing counted strings in the file just use
   a single `stringUnit` with `%lld`, match THAT simpler shape instead — consistency
   with the file wins over theoretical correctness.
4. Keep the file valid JSON, keys sorted as the tool writes them (don't reorder
   existing entries), and do not touch the 253 already-complete strings.

## Verify

- `python3 -c "import json; json.load(open('Dspeech/Localizable.xcstrings'))"` — valid.
- Re-run the gap check: 0 strings missing any of the 10 locales.
- Full `xcodebuild ... build test` green (xcstrings compiles; a malformed entry fails
  the build). Zero warnings.
- Print, in your summary, the French (`fr`) and Russian (`ru`) value for all 32 keys
  so the reviewer can read them.

Commit: `feat(l10n): translate core-semantics strings into all shipped locales`.
