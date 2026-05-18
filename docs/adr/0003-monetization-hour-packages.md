# ADR 0003: Monetization = hour-bundle packages

## Status

Accepted 2026-05-18.

## Context

Andrei (Notion 2026-05-18): "пилоты платят за фактически использованное время. Покупает пакеты часов и потом их юзают". Pilots use the app intermittently — sometimes 0 hrs/month (ground), sometimes 80+ hrs/month (rotation cycles). A flat subscription mis-prices both ends.

Comparable anchors:

- **Otter.ai** (ASR, general): ~$30/mo for ~30 h transcript → ~$1/h, but ASR-only, English-dominant, no aviation domain.
- **Rev** (human-grade ASR): ~$0.25/min ≈ $15/h.
- **ForeFlight Performance Plus** (aviation reference data): ~$30/mo flat (≈ $360/yr), no audio.
- **SkyDemon** (Europe charts): ~£165/yr flat.
- **PilotEdge** (sim ATC): ~$20/mo flat.

Aviation niche + translation + privacy positioning → premium per-hour anchor, but bundling makes per-hour drop quickly so heavy users are not punished.

## Decision

App billing is **hour-bundles**, consumed when the ASR/translation pipeline is actively running and producing transcript output. Background time, paused state, and pre-roll do not consume.

Default catalog (Tier A — see pricing doc for regional fences):

| SKU | Hours | Price (Tier A) | Effective $/h | Position |
|---|---|---|---|---|
| `trial` | 1 | $0 | 0 | Trial, one per Apple ID |
| `starter_10` | 10 | $39 | $3.90 | Try-and-see |
| `standard_50` | 50 | $129 | $2.58 | Default recommended |
| `pro_200` | 200 | $399 | $2.00 | Heavy line pilots |
| `career_unlimited_year` | unlimited / 12 mo | $999 | n/a | Flight-school instructors, captains on intl long-haul |

Pack hours **never expire** once purchased. The `career_unlimited_year` SKU is the only time-bounded one.

## Consequences

- Need an in-app meter: precise minutes-of-pipeline-active counter, persisted locally, idempotent against crash/restart.
- Need StoreKit 2 implementation for consumable IAPs (hour packs) plus one auto-renewable (career).
- Receipt/entitlement validation is local first; server-side validation only if a cloud-mode account exists (deferred — `.localOnly` users have no account).
- Refund/disputed-time policy needed before App Store submission (`docs/product/hourly-package-model.md`).

## Non-decisions

- Whether unused trial hours roll into a purchased pack.
- Whether shared-account households (CFI + student) get a discount.
- Family Sharing eligibility — likely off for consumables, on for `career`.
