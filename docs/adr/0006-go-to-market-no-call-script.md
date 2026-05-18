# ADR 0006: Go-to-market — app + landing + App Store + paid social + AI sales bot. No cold-call script.

## Status

Accepted 2026-05-18. Source: Andrei Notion comments:
- «колл скрипт не надо, делаем лендос и листим в аппстор, делаем инсту тикток ютуб и начинаем делать шортсы и рекламить их таргетом и смотрим отстуки и конверсию»
- «Продажи через ИИ чатбота на сайте или в апке или в соцсетях в директе через hermes агента который будет продавать отвечать и создавать сапорт тикеты итд»

## Context

Three sales motions were on the table: (a) cold-call script + manual outreach, (b) landing page + App Store listing + short-form social content + targeted ads, (c) AI sales/support chatbot answering inbound on website / in-app / social DMs. Manual cold-call outreach does not scale and burns the founder's most expensive hours.

## Decision

- **No cold-call script.** No manual sales-call playbook lives in this repo.
- **Acquisition channels:** `dspeech.com` landing page, App Store listing, short-form content on Instagram / TikTok / YouTube Shorts, targeted ads against those shorts. Measure click-through and conversion. Iterate on data, not opinion.
- **Sales / support layer:** Hermes-powered AI chatbot answers inbound on website, in-app chat, and social DMs. Concept doc: `docs/product/hermes-sales-bot.md`. Positioning + landing + App Store draft copy: `docs/product/launch-positioning.md`. Pricing grid (top-20 markets, CIS excluded): `docs/product/pricing-top20-aviation.md`.
- The build-phase team does **not** ship ads, submit to the App Store, or run any outbound campaigns without explicit Andrei sign-off on creative and budget.

## Out of scope (this iteration)

- Running paid ads.
- Submitting the App Store listing.
- Sending DMs to pilot lists, aviation forums, or Slack/Discord channels.
- Creating IG/TikTok/YouTube accounts under the Dspeech brand.
- Implementing the Hermes sales bot in code. Concept doc only.

## Consequences

- The iOS app may include a hook for a future in-app AI assistant surface (e.g. a "Help" sheet), but no fake/staged chat UI that pretends an AI is live until the Hermes agent is actually wired.
- The landing page lives in a separate repo / surface (`dspeech-landing`, to be created later), not in this iOS repo.
- A follow-up ADR will define the Hermes integration boundary when implementation starts.
