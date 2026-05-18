# Launch positioning — landing + App Store + paid social

Status: draft v1 (2026-05-18). No call script (explicitly rejected by Andrei). All assets here are drafts; nothing published, nothing spent.

## Positioning one-liner

> "Большой, читаемый перевод диспетчера прямо в кабине. Аудио остаётся на iPhone."
> EN: "Big, readable ATC transcript and translation right in the cockpit. Your audio stays on your iPhone."

Frames: supplemental aid (not certified, not ATC-authoritative), original audio is canonical, privacy-by-default.

## Landing page outline (`dspeech.com`)

Sections, top-to-bottom:

1. **Hero**: 8-word headline + the device mock-up screenshot in landscape transcript view. Single CTA: "Скачать в App Store" (when listed) / "Я первый узнаю когда выйдет" (now → email opt-in).
2. **What it does**: 3 cards — *Слышу диспетчера*, *Вижу крупный текст*, *Понимаю на родном языке*.
3. **Privacy**: dedicated section, headline "Ваше аудио не уходит с телефона". Three bullets: on-device ASR, on-device translation, cloud is opt-in.
4. **Pricing**: hour-pack grid (3 SKUs visible, Career as small "for instructors" link). Trial=1h front and centre.
5. **Disclaimer block**: supplemental aid, original audio canonical, not for sole-source ATC dependency. Required for App Store + legal honesty.
6. **FAQ**: 8 entries — hardware? privacy? offline? aircraft types? non-English ATC? CFI accounts? refund? data retention?
7. **Footer**: imprint, privacy policy, terms, support email, social.

Frameworks shortlist (verify via Context7 before build): Next.js 15 + MDX for content, deployed on Cloudflare Pages from the `dspeech-landing` repo (to be created later — out of scope this dispatch).

## App Store listing (draft copy)

- **Name**: `Dspeech — ATC transcript & translate`
- **Subtitle**: `Cockpit-friendly ATC reader`
- **Promotional text**: 170 chars — "Большой текст диспетчера в кабине. On-device. Без подписок. Пакеты часов — платите за факт использования."
- **Description**: lead with privacy + supplemental-aid framing, then features, then hour-pack pricing, then disclaimer. Must include "supplemental aid, original audio is canonical, not certified".
- **Keywords**: aviation, atc, cockpit, pilot, transcription, translate, intercom, captain, copilot, gа.
- **Category**: Primary `Productivity`, Secondary `Travel` (revisit after listing).
- **Age rating**: 4+.
- **Pricing**: free + IAPs (`starter_10`, `standard_50`, `pro_200`, `career_unlimited_year`).
- **Privacy nutrition label**: Data NOT collected = audio, transcript, location, identifiers, usage data (in `.localOnly` mode default).

## Paid social plan — IG / TikTok / YouTube Shorts

Hypothesis: pilots are reachable on IG (aviation hashtags, Captain/FO creators), TikTok (#avgeek, #pilotlife), YT Shorts (cockpit POV channels). LinkedIn deferred (low video CTR).

### Content pipeline (drafts only, no publishing yet)

Three repeating short-form formats:

1. **"Что сказал диспетчер?"** — 6–10 s clip of muffled ATC audio with the Dspeech transcript overlay, then the translation reveal. Hook = ambiguity.
2. **"Большой текст для пилота"** — landscape iPhone mock showing transcript scale, with the phrase "когда зрение уже не то, как у курсанта".
3. **"Локально, не в облаке"** — privacy framing, 8 s, transcript appearing on airplane-mode iPhone.

Cadence: produce 3 variants per format per week (9/week). One creative direction file per week, never one-off.

### Paid ads — testing loop

Initial test budget cap (not approved here, draft only): per-platform €300 over 7 days.

Per platform:

- **Meta (IG/FB)**: Advantage+ campaign, 1 ad set, 3 creatives. Audience = interests {aviation, pilot, ATC, aircraft, ForeFlight, SkyDemon}, ages 22–60, geo = Tier A countries only. Optimization: link clicks → App Store listing.
- **TikTok**: Spark Ads from organic posts. Same geo. Optimization: app installs (once listed) or link clicks (pre-listing).
- **YouTube Shorts**: Performance Max for Apps (when listed). Pre-listing: standard video campaign optimizing for landing visits.

Success metrics, weekly:

| Metric | Target | Action if missed |
|---|---|---|
| CTR | ≥ 1.2% | Recreate hook variants |
| Cost per landing visit | ≤ €0.50 (Tier A avg) | Narrow audience |
| Email opt-in rate (pre-listing) | ≥ 8% of visits | Rewrite hero |
| App install rate (post-listing) | ≥ 12% of visits | Improve listing screenshots |
| Trial → paid conversion | ≥ 9% within 14 d | Adjust trial length / first-pack price |

All numbers are hypotheses. We re-fit after first 14 days of real data.

## What I am NOT doing in this dispatch

- Not creating IG/TT/YT accounts. Not buying landing domain hosting. Not running ads. Not submitting to App Store. Drafts only.
- Not contacting any pilot, school, or airline directly.
