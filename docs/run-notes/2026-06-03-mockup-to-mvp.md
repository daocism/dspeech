# 2026-06-03 — mockup → MVP: three transcript bugs, root causes, and the pattern behind them

User report: (1) default recognition language should always equal the device language;
(2) live transcription "пишет на экран в другом ваще виде не как демо"; (3) pressing Stop
makes the transcribed text disappear. Plus a standing directive: on every bug, do a
pattern-level self-retro, not just a technical fix.

## Bug 1 — default recognition language was not centered on the device language
- **Symptom:** default felt English-y, not the user's device language.
- **Tech cause:** `RecognitionLocaleCatalog.defaultIdentifier` matched by language code but
  with non-deterministic region selection (Set iteration) and a raw-string exact path that
  missed Locale canonicalization (`ru-RU` → `ru_RU`).
- **Fix (68bac73):** resolve to the device language whenever Apple Speech supports it — exact
  device locale → same language code (device region preferred) → English only as last resort.
  Canonical comparison, sorted for determinism. Tests: ru→ru-RU, en-GB region, ru-KZ→ru-RU.

## Bug 2 — live transcript rendered unlike the polished demo
- **Symptom:** while listening, text appeared as a cyan italic monospace block, jarringly
  unlike the white demo cards.
- **Tech cause:** `PartialTranscriptCard` had its own foreign styling (cyan bg, italic) vs
  `TranscriptSegmentCard` (white card, large mono). The polished thing on screen was the
  *demo mockup*; the real live path was never made to match it.
- **Fix (24f455f):** the partial card now mirrors the segment card's layout/typography with
  only a small `LIVE` badge — live text reads as the same transcript, just in progress.

## Bug 3 — Stop wiped the transcript
- **Symptom:** transcribe, press Stop → it all disappears.
- **Tech cause:** on Stop the engine tears down and the VM cleared `partialText`; if the
  recognizer hadn't finalized a segment, the in-progress line was discarded. The demo
  placeholder then reappeared (shown whenever there were no live segments and status was
  idle/stopped).
- **Fix (24f455f):** Stop commits the in-progress partial as a segment (confidence 0 →
  VERIFY badge, 0% hidden) so it persists; the demo is now first-run-only (`hasEverStarted`)
  and never reappears over a real session. Tests: stop-commits-partial, stop-with-no-partial.

## The PATTERN (not the technical errors) — banked globally
All three (and the earlier mic-crash + test-theater in the same session) are one pattern:
**I polished the demo/mockup (and trusted green tests) and never drove the REAL user flow —
start → speak → see MY transcript → Stop → it stays, in MY language.** The mockup looked
done, which anchored the judgment; the real path was broken and unpolished.
Re-tuned in global feedback memory: `mockup-masquerades-as-done` and the standing
`per-bug-pattern-retro` directive. How to catch earlier: treat demo/fake/placeholder as
scaffolding to remove, run the real flow yourself, and specifically test transitions +
teardown (Stop / cancel / empty / relaunch) in the user's actual locale.

## Verification
Simulator suite green (327 tests; parallel-off avoids the pre-existing translation-test
parallel flake). Real end-to-end transcription is device-only (the Simulator has no speech
HAL and hard-errors on server recognition — confirmed) — visible skip on the Simulator, runs
on a device. Installed on the iPhone 15 Pro Max for live-flow verification.
