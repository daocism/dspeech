# Cloud fallback — cost & privacy matrix

Date: 2026-05-18. Status: draft. Implements the cost+privacy table promised under ADR 0002 ("Non-decisions deferred — exact list of cloud providers").

## Purpose

If a user opts into `PrivacyMode.allowCloudFallback`, which cloud providers are we willing to call, at what cost per minute, with what data-leaving-the-device profile?

## Anti-goals

- This document does NOT enable cloud paths in the product. Andrei must explicitly accept a row before code is written.
- This is not a procurement contract — prices below are **public list anchors** captured 2026-05-18; rerun before signing anything.

## ASR providers

| Provider | Model | List price (anchor) | Data residency options | Audio retention default | Opt-out of training | Verdict (for Dspeech) |
|---|---|---|---|---|---|---|
| OpenAI | `whisper-1` API | ~$0.006 / minute | US default; EU via Azure resold paths | "kept for abuse monitoring up to 30 days" (verify at signing) | Yes via BAA / API DPA | Acceptable IF Andrei OKs US data residency for non-EU users; not default. |
| OpenAI | `gpt-4o-audio` realtime API | Higher (per-minute, see vendor docs) | US | Same as Whisper | Yes | Premium tier candidate only. |
| Deepgram | `nova-3` general | ~$0.0058–$0.0072 / minute streaming (verify) | US, EU | Configurable, default short retention | Yes contractually | Best perf/$ on telephony-band audio; good aviation-domain candidate. |
| AssemblyAI | `universal-2` | ~$0.005 / minute streaming (verify) | US default | Configurable | Yes contractually | Comparable; vibe is product-focused. |
| Azure Speech | Custom Speech / aviation domain | Higher fixed-cost option | Multi-region incl. EU | Configurable | Yes | Heavy ops; only if a customer mandates Azure. |
| Google Speech-to-Text | `chirp_2` | ~$0.0024–$0.016 / minute (model-dependent, verify) | Multi-region | Configurable | Yes | Backup option. |

Numbers are **list anchors** and must be re-confirmed when any cloud path is approved.

## MT providers

| Provider | Model | List price (anchor) | Data residency | Verdict |
|---|---|---|---|---|
| DeepL | API Pro | ~€20 / 1M chars (verify, EUR/USD vary) | EU default | High quality for European pairs; EU-friendly default. |
| Google Translate | v3 | $20 / 1M chars (verify) | Multi-region | Backup. |
| OpenAI (gpt-4o-mini) | as MT | $0.15 / 1M tokens input, $0.60 / 1M output (verify) | US default | High quality, terminology-aware; pricier per char. |
| Anthropic (claude-haiku) | as MT | Per token (verify) | US default | Option. |

## Privacy classification per row

| Tier | What leaves the device | When allowed |
|---|---|---|
| T0 — Local only | Nothing audio/transcript | Default; `PrivacyMode.localOnly` |
| T1 — Catalog metadata | Pack version IDs, app version | Always (compatible with .localOnly per ADR 0002) |
| T2 — Cloud MT only | Final ASR text segments (no raw audio) | Requires `.allowCloudFallback` + Settings opt-in + per-session badge |
| T3 — Cloud ASR | Raw audio segments | Requires explicit per-session re-confirm; off by default even within `.allowCloudFallback` |
| T4 — Cloud ASR + cloud MT | Audio + transcript | Same as T3 + T2; explicit double confirm |

The runtime privacy badge resolves as: T0/T1 → `LOCAL`; T2/T3/T4 → `CLOUD`. Per-segment transcript metadata records the tier (already planned per ADR 0002 follow-up).

## Cost model (sanity check vs hourly packages)

`docs/product/hourly-package-model.md` defines hour-based pricing. Sanity:

- 1 h of T3 ASR (Deepgram nova-3) ≈ 60 × $0.006 = **$0.36 / hour**.
- 1 h of T2 MT only (DeepL on 12000 chars/hour estimate) ≈ €0.24 / hour.
- 1 h of T4 (ASR + MT, OpenAI whisper + DeepL) ≈ $0.36 + €0.24 ≈ $0.62 / hour.

These are deeply margin-positive against any reasonable hour-pack list price. Cloud path is therefore economically viable; the gate is privacy posture, not unit economics.

## Open questions (Andrei action required)

- Pick the first cloud ASR provider to enable (Deepgram appears best perf/$). Sign DPA before any code.
- Pick the first cloud MT provider (DeepL appears best for EU pairs; DeepL has EU residency by default).
- Confirm EU-vs-US data-residency posture for the EU pilot market.

## References

- ADR 0002, `prd-ios-mvp.md`, `language-pack-spec.md`, `hourly-package-model.md`, `regulatory-privacy-memo.md`.
