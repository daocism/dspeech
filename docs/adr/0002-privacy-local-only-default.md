# ADR 0002: Privacy = local-only by default

## Status

Accepted 2026-05-18. Confirms and tightens ADR 0001.

## Context

ADR 0001 said "local-first" — cloud could exist as an explicit fallback. Andrei (Notion 2026-05-18) clarified: ship **local-only by default**. Cloud ASR/translation never enabled silently; the user must turn it on explicitly per session or in Settings, and we must surface clearly that audio is leaving the device.

Cockpit audio contains route, pilot voice, flight number, position, and operational data. Privacy treatment is non-cosmetic.

## Decision

1. Introduce a domain enum `PrivacyMode` with two cases: `.localOnly` (default), `.allowCloudFallback`.
2. App constructs every ASR and translation pipeline with `PrivacyMode.localOnly` unless the user has explicitly switched. There is no "auto-fallback to cloud" path.
3. Settings shows an explicit "Конфиденциальность / Privacy" section stating the current mode in plain language. Switching to cloud requires confirmation and a one-line disclosure.
4. `requiresVerification` semantics remain; cloud-derived segments must additionally be flagged in transcript metadata (future work — tracked as a follow-up, not in this dispatch).
5. App Store description and landing page must state "all audio stays on your iPhone by default" verbatim or near-verbatim.

## Consequences

- ASR adapter shortlist must include at least one fully on-device option (Apple Speech, WhisperKit/Core ML) before any cloud adapter ships.
- Translation: only local pack / on-device models in default mode. Cloud translation gated.
- Marketing message has a hard anchor: privacy is a feature, not a tradeoff.
- Engineering: a small amount of plumbing (`PrivacyMode` carried through service factories). No analytics hook may transmit audio/transcript content under `.localOnly`.

## Non-decisions (deferred)

- Exact list of which cloud providers will be allowed once `.allowCloudFallback` ships.
- Whether opt-in is per-session or sticky.
- Whether crash logs include redacted transcript samples.
