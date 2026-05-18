# Dspeech iOS MVP — PRD

Date: 2026-05-18. Owner: tech-lead (under Andrei). Status: draft for engineering slice; non-binding until ADR-promoted.

## Goal (one sentence)

Pilot/student-pilot iPhone app that turns cockpit/ATC speech into large, glanceable text on-device, with an optional one-tap translation overlay, all running locally by default.

## Non-goals (MVP)

- Cloud ASR as a default path. (ADR 0002.)
- Recording for legal/training playback. (Receive-only product, see ADR 0004.)
- Android, watchOS, CarPlay.
- Speaker diarization, pilot-vs-ATC attribution. (Stretch.)
- Voice synthesis / read-back. (Receive-only.)
- Flight-data integration (ADS-B, AHRS, EFB).

## Users & jobs-to-be-done

1. **Student pilot under hood**: "Read what ATC just said — I missed the call sign."
2. **Non-native English pilot in cruise**: "Show me the Russian/Ukrainian gloss of the readback I just got."
3. **Instructor on the ground**: "Show me what the student copied vs. what was actually said." (post-flight, stretch).

## Surfaces

### 1. Main view ("cockpit")
- Big monospaced transcript area, top-aligned, last-N segments visible. Tap a segment → expand details (timestamps, confidence).
- Top-right: privacy badge `LOCAL` / `CLOUD` (shipped; ADR 0002).
- Bottom control bar: `[Start]` `[Stop]` `[Перевод toggle]` `[⚙ Settings sheet]`.
- Translation toggle behavior:
  - OFF (default): only ASR transcript visible.
  - ON: each finalized ASR segment gets a translation line under it (smaller font, italic), in the user's chosen target language. Source language detected/locked from ASR.
  - When toggled ON while `PrivacyMode.localOnly`: only on-device translation packs are used. Missing pack → one-tap "Download pack — N MB" CTA; never silent cloud fallback.
  - When toggled ON while `PrivacyMode.allowCloudFallback`: cloud MT may be used; badge stays `CLOUD`; per-segment cloud-flag in metadata.

### 2. Settings sheet
- Privacy section (shipped).
- Audio source: `Built-in mic (demo)` / `Wired input (USB-C / TRRS)` / `AirPods (poor, warn)` selectable, with a "Test level" meter. See `audio-input-matrix.md`.
- Translation: target language picker; installed packs list with size + delete; "Download more packs".
- About: build/version, ADR links, "what data leaves the device" disclosure.

### 3. First-run flow
- 3 cards: (1) "Receive-only — Dspeech does not transmit on the radio." (2) "Local by default — your audio stays on this iPhone." (3) "Wire it for cockpit accuracy — built-in mic is for trying the app." Each card ≤ 2 short sentences.
- No account, no email, no analytics opt-in dialog (no analytics under `.localOnly` per ADR 0002).

## Functional acceptance (MVP gate)

| # | Capability | Gate |
|---|---|---|
| F1 | Live ASR on iPhone 15 or newer | English aviation-domain phrases at SNR ≥ 10 dB → WER ≤ target in `asr-benchmark-plan.md` |
| F2 | Big readable transcript | 17pt+ monospaced, dynamic-type respected, dark mode |
| F3 | Translation toggle | Adds gloss line, never blocks ASR, never silently uses cloud |
| F4 | Privacy badge always visible | LOCAL / CLOUD, accessibility label distinct from visual |
| F5 | Audio source picker | At minimum built-in + wired; saved per device |
| F6 | Crash-free session ≥ 60 min | Zero crashes on a single battery charge during continuous ASR |
| F7 | Battery budget | ≤ 25% drain per 60 min continuous ASR on iPhone 15 baseline (target; verify in benchmark) |
| F8 | Backgrounded behavior | Stops ASR cleanly when app backgrounds (no covert background capture) |

## Dependencies / open questions

- ASR adapter shortlist: Apple Speech vs WhisperKit (Argmax). Decided by `asr-benchmark-plan.md`.
- Translation: Apple Translation framework (on-device) vs bundled NLLB-distilled CoreML packs. Decided by `translation-benchmark-plan.md`.
- Minimum iOS: assume 26.0. Confirm after benchmark.

## References

- ADR 0001, 0002, 0004, 0005.
- `docs/architecture.md`.
- `docs/eval/asr-benchmark-plan.md`, `docs/eval/translation-benchmark-plan.md`, `docs/eval/evaluation-corpus-spec.md`, `docs/eval/audio-input-matrix.md`, `docs/eval/terminology-guard-spec.md`.
- `docs/product/language-pack-spec.md`, `docs/product/cloud-fallback-matrix.md`, `docs/product/regulatory-privacy-memo.md`, `docs/product/competitor-teardown.md`.
