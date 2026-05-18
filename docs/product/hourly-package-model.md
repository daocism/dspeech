# Hourly-package model — operational spec

Status: draft v1 (2026-05-18). Owned by product. Implementation tracked separately (StoreKit 2 + meter).

## Why hours, not subscription

Pilots' usage is bimodal: heavy during 4–6 day rotations, near-zero off-rotation. A flat $30/mo punishes light-duty months and under-charges line captains. Hour packs let usage track value 1:1 and remove the "should I cancel for this month" friction loop.

User language: "сколько часов осталось", not "what tier am I on".

## What counts as a billable hour

1 hour = 60 minutes of **pipeline-active** wall-clock, where:

- ASR is consuming audio AND producing transcript output (`AsyncStream<TranscriptSegment>` yielding).
- App is in foreground OR the user has explicitly granted background-audio mode for this session.

Does NOT count:

- App open but pipeline paused (user tapped pause, or no audio energy threshold for >5 s).
- Pre-roll buffer / silence at the start of a session.
- Translation-only pass on an already-transcribed segment (translation is free once ASR is paid).
- Crashed/aborted sessions — only committed transcript time counts.

## Meter contract

- Persisted locally in encrypted Core Data store under user keychain item `com.dspeech.meter.v1`.
- Counter is monotonic, append-only journal of `(sessionId, startedAt, endedAt, secondsConsumed)`.
- Crash-safe: every 30 s of pipeline activity, journal flushed; on relaunch, unfinished journal entries close with their last flush timestamp.
- Idempotent: same `sessionId` cannot double-deduct.
- Source of truth is local. No server-side reconciliation in `.localOnly` mode (see ADR 0002).

## Wallet / entitlement model

```
Wallet {
  freeTrialSecondsRemaining: Int   // capped at 3600
  paidSecondsRemaining: Int        // sum of all pack purchases minus consumed
  careerActiveUntil: Date?         // if set and > now, treats paidSeconds as infinite
}
```

Deduction order per second:

1. If `careerActiveUntil > now` → no deduction.
2. Else if `freeTrialSecondsRemaining > 0` → decrement trial.
3. Else if `paidSecondsRemaining > 0` → decrement paid.
4. Else → stop pipeline, show "Купить пакет / Buy hours" sheet, allow already-rendered transcript to remain visible.

## Purchase paths

- StoreKit 2 consumables: `starter_10`, `standard_50`, `pro_200`. Each grants `hours × 3600` seconds to `paidSecondsRemaining`.
- StoreKit 2 auto-renewable: `career_unlimited_year` → sets `careerActiveUntil = now + 365 days`. Renewal extends.

Purchases are validated locally via Apple's signed transaction JWS. No external billing path (Stripe/Paddle) in v1.

## Refunds & disputes

- Apple handles consumable refunds via App Store. If a refund webhook arrives (only relevant once cloud account exists), we credit back the seconds.
- In `.localOnly` mode there is no webhook → policy is "all sales final; Apple refund window applies." This must appear in App Store description.

## Edge cases handled

- Clock change/timezone: meter uses `CLOCK_MONOTONIC`-style relative measurement, not wall clock, so DST/timezone shifts don't add/subtract time.
- Multiple devices same Apple ID: in `.localOnly` mode, each device has its own wallet — purchases restore via Apple's purchase history, hour balance does NOT sync across devices in v1. Documented in App Store description.
- Family Sharing: consumables not shared. `career` shareable (Apple default) — flag in store config.

## Out of scope v1

- Cross-device hour sync (requires cloud account).
- Gifting flow beyond Apple's built-in gift IAP.
- Pay-as-you-go (per-minute charge with credit card on file) — explicitly rejected by Andrei's "пакеты часов" framing.
- Variable pricing by aircraft type or pilot rank.

## Test plan (high level)

- Unit: `WalletDeduction` table-driven cases — trial → paid → career transitions.
- Integration: StoreKit 2 sandbox purchase → wallet update → meter consumes → wallet decremented.
- Crash test: kill pipeline mid-session, restart, journal must replay deterministic seconds.
