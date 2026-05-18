# Hermes-based AI sales & support bot — concept

Status: concept draft (2026-05-18). Implementation is out of scope this dispatch. This document scopes the agent so a future engineering dispatch can build it.

Source: Andrei's Notion comment on page `361dfa2b-7893-81c4-a412-c56e67af8f56` — "Продажи через ИИ чатбота на сайте или в апке или в соцсетях в директе через hermes агента который будет продавать отвечать и создавать сапорт тикеты итд".

## Goal

Single conversational agent that handles three jobs across web, in-app, and social DMs:

1. **Sales** — qualify visitor, recommend the right hour-pack, deep-link to App Store or trigger in-app StoreKit.
2. **Support** — answer FAQ, resolve trivial cases (how to pause, where's my balance, restore purchases), and create a ticket when it can't.
3. **Ticket creation** — every conversation that ends without resolution opens a ticket in the support backlog with full transcript + classification.

Brand persona: terse, factual, aviation-literate, no fake enthusiasm. Mirrors Dspeech product voice.

## Surfaces

| Surface | Channel | Identity |
|---|---|---|
| Website | floating chat widget on `dspeech.com` | "Dspeech assistant" |
| iOS app | help sheet, only when user opens "Help" | same identity |
| Instagram DM | business inbox via Meta Graph | same identity, manual fallback during business hours initially |
| TikTok DM | TikTok Business Messaging API | same identity, manual fallback |
| YouTube comments | community manager only (no auto-reply on YT in v1) | n/a |

## Architecture (high level, not a build spec)

```
[ surfaces ] ──webhook──> [ Hermes gateway (existing fleet) ]
                                │
                                ▼
                       [ Dspeech-sales agent (new) ]
                                │
                  ┌─────────────┼────────────────┐
                  ▼             ▼                ▼
           [ KB (md docs)  [ Support API   [ Sales API
             pricing/      (tickets,       (StoreKit
             FAQ/privacy)   tags, SLA)      links, pricing) ]
```

- Re-uses the existing Hermes infra on `mini-pc` (see MyInfra memory). Adds one new agent persona; no new host.
- Knowledge base sources are the canonical repo docs: `docs/product/pricing-top20-aviation.md`, `docs/product/hourly-package-model.md`, `docs/adr/0002-privacy-local-only-default.md`, `docs/architecture.md`. The KB is rebuilt on every commit to `main` so the bot is never out of date vs reality.
- Support tickets land in a lightweight store (Postgres on `voyage`) with fields `{id, surface, user_handle, transcript_url, category, sla_due_at, status}`.

## Sales loop

1. Visitor lands on chat with intent: "сколько стоит?" / "what about privacy?" / "does it work without internet?".
2. Bot answers from KB, then asks one qualifying question: cockpit type (airline/GA/sim/curious).
3. Recommends a pack: GA/private → `starter_10`; line/airline → `standard_50` default, `pro_200` if "more than 50 h/mo"; CFI/school → `career_unlimited_year`.
4. Closes with a deep link (App Store listing URL or in-app `dspeech://buy?sku=...`).
5. If user says "later/think" → captures email, drops to nurture queue (out of scope to actually send anything in v1; just captured).

## Support loop

1. Bot tries FAQ + KB lookup.
2. If confidence < threshold OR user explicitly asks human → bot creates ticket, hands off, returns ticket ID.
3. Tickets are listed in a Hermes-served operator UI on `mini-pc` (existing pattern).

## Safety / OWASP-LLM rails

- **LLM01 Prompt Injection**: untrusted DM content is parsed as user text only; tool calls are gated by an allow-list (deep-link emit, ticket-create, KB-query). The bot cannot run shell, edit pricing, or send arbitrary URLs.
- **LLM02 Insecure output**: every URL the bot emits is restricted to a hard-coded allow-list of domains (`dspeech.com`, `apps.apple.com`).
- **LLM06 Excessive agency**: bot cannot issue refunds, cannot change pricing, cannot impersonate Andrei, cannot DM-out without a human-initiated thread.
- No PII leakage: support ticket transcripts redact pasted credentials/PII via a pre-store filter.

## Why "Hermes"

Re-use the existing fleet's agent runtime so we don't add a new server stack. Existing Hermes deploys on `mini-pc`/`cianpan`/`voyage` already handle Telegram and webhook patterns; adding a `dspeech-sales` persona is a config change, not new infra.

## What this doc is NOT

- Not an implementation. No code, no API contract beyond the high level.
- Not a launch deliverable. Built after the iOS app has a real App Store listing or a real public landing page.
- Not autonomous outbound. The bot does not initiate conversations; it only responds.
