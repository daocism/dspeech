# ADR 0005: Build the app first — cockpit/flight validation comes later

## Status

Accepted 2026-05-18. Source: Andrei Notion comment («Надо делать аппку щас а потом уже будем тестить в кабинах и полётах»).

## Context

Two work streams competed for the same bandwidth: (a) finish a shippable iOS app on the local-first pipeline, (b) recruit pilots and run cockpit / cabin validation in parallel. With no real ATC corpus on hand and no buildable app yet, doing both in parallel produces neither.

## Decision

Sequence, do not parallelize:

1. **Now** — build the iOS app: local-first transcription pipeline, replay/file-based ingestion, transcript surface, privacy settings, basic verification UX. Reproducible benchmarks on the replay corpus.
2. **Later** — in-cockpit / in-flight validation: only after the app is buildable, installable on TestFlight, and reproducible against a recorded corpus.

No pilot recruitment, no cockpit field testing, no flight-line outreach during the build phase.

## Consequences

- Replay-file ingestion is prioritized over live audio capture (also implied by ADR 0004).
- The cockpit test plan becomes a separate doc to be written **only after** we have a buildable app and a corpus.
- Marketing/positioning surfaces (landing, App Store listing draft, social) may proceed in parallel (see ADR 0006) **provided they do not claim cockpit validation that has not happened**.

## Non-decisions

- Exact criteria that flip "build phase" → "cockpit-validation phase". Likely: app installable on TestFlight + ≥ 10 hours of representative replay corpus benchmarked + local-only ASR baseline within target WER.
- Whether the first cockpit testers are recruited via existing relationships or via the GTM funnel from ADR 0006.
