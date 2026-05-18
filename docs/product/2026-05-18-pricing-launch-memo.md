# Dspeech — Pricing & Launch Memo

- **Date:** 2026-05-18
- **Author:** team-architect (product/research strategist persona), dispatched via Mr.Dao
- **Status:** v0.1 — first-pass strategy memo. Pricing bands and market sizing labelled `[ASSUMPTION]` where not yet anchored to a fetched source. Source-gap TODOs are listed in §11.
- **Audience:** Andrei (product owner) + downstream agents (landing-page agent, App Store listing agent, Hermes sales-bot agent, paid-acquisition experiment agent).
- **Non-goals:** No outreach sending. No ad spend. No App Store submission. No external account changes. No CIS pricing (excluded per directive).
- **Canonical rules respected:** receive-only, supplemental/non-certified positioning; original captured audio is the source of truth, transcript is an aid; no safety-of-flight claims.

### Relation to sibling product docs (mobile agent, same day)

The mobile implementation agent landed four slice docs in this directory:

- [`pricing-top20-aviation.md`](pricing-top20-aviation.md) — Tier A/B/C country list (operational quick-ref).
- [`hourly-package-model.md`](hourly-package-model.md) — StoreKit 2 / meter / wallet engineering spec.
- [`launch-positioning.md`](launch-positioning.md) — landing + App Store + shorts plan.
- [`hermes-sales-bot.md`](hermes-sales-bot.md) — bot concept doc.

This memo is the **strategic synthesis** sitting above them: it adds (1) explicit PPP-banded pricing grid, (2) full comparable-anchor map with read-across, (3) `[ASSUMPTION]`-labelled prices + a §11 source-gap TODO list so nothing leaks into App Store Connect unverified, (4) §10 binary product decisions for Andrei. Where the country list (§1) or banding (§3) here disagrees with `pricing-top20-aviation.md` (Belgium / Singapore vs Finland / Norway; A/B/C vs A/B/C/D), the two should be reconciled in a follow-up commit *after* §11 numeric anchors are pulled — neither is right on data yet.

---

## 0. Strategic frame (the wedge)

Dspeech is an **iOS-first, receive-only ATC + intercom transcription/translation companion** for pilots, flight schools, and CFIs. The fastest path to profitable paid revenue is:

1. **Wedge users**: solo English-second-language pilots flying in English-ATC airspace + ab-initio students at non-English-native flight schools (Western Europe, East Asia, Gulf). They feel ATC comprehension pain every flight and pay for tools that reduce it.
2. **Wedge offer**: hours-of-use packages plus a thin monthly subscription. Pilots already think in flight-hours, intercom-hours, and sim-hours — the unit matches their mental model.
3. **Pull, not push**: landing page + App Store listing + organic short-form video (TikTok, Reels, Shorts) demonstrating real cockpit transcription. Paid ads only as an amplifier on the variants that already convert organically.
4. **AI sales/support on rails**: a Hermes-driven chatbot on the site + in social DMs that qualifies, answers, and creates a support ticket; no autonomous billing/account actions until human-in-the-loop graduates it.

The build sequencing (app now → cockpit/flight tests later → no hardware purchase now) is reinforced by this memo: every revenue stream below works against the current build scope and does **not** require certification, hardware shipping, or App Store paid publication on day one. Paid sale can start as a TestFlight closed-beta with a Stripe-collected deposit; App Store launch is the second beat, not the first.

---

## 1. Top-20 developed aviation markets (CIS strictly excluded)

Selection rubric (each country scored qualitatively on five proxies; full numeric anchoring is a §11 TODO):

- **(A) Active pilot population** — proxy: ICAO Annex 1 licence stock, AOPA/EASA/CAA published pilot counts.
- **(B) GA fleet size & training throughput** — proxy: registered piston/SE-IFR, ATO/Part-141/EASA-ATO count, ab-initio cadet throughput at named majors (CAE, L3 Harris, Lufthansa Aviation Training, Etihad Aviation Training, FlightSafety, ATP, etc.).
- **(C) English-ATC environment with measurable comprehension friction** — proxy: ICAO Level 4 English requirement enforcement + non-English-native population flying in English airspace, e.g. JP/KR/DE/FR/IT/ES regional + Gulf carrier cadets.
- **(D) Willingness to pay for pilot software** — proxy: ForeFlight/SkyDemon/Garmin Pilot install bases, EFB-mandate adoption, average aviation app ARPU.
- **(E) App Store / payments rails health** — proxy: App Store revenue rank, Stripe/Apple Pay coverage, payment-method friction.

Tier 1 (anchor markets — launch here first):

| # | Country | Why it's in | Primary persona for Dspeech |
|---|---|---|---|
| 1 | **United States** | Largest GA fleet & active pilot stock globally; ForeFlight/Garmin Pilot price ceiling already established. (A,B,D,E very high.) | Private pilot ESL immigrants, CFIs running ESL students, Part 141 schools with international cadets. |
| 2 | **Canada** | Large GA, bush + IFR mix; ESL cadet flow at western Canadian ATOs. | Same as US + ATO student. |
| 3 | **United Kingdom** | EASA-aligned UK CAA; major ATO hub (L3 Harris, CAE Oxford, Skyborne); high WTP. | International ATPL cadet, weekend PPL. |
| 4 | **Germany** | Largest EU GA fleet; Lufthansa Aviation Training; English ATC mandatory above FL100; very heavy ICAO Level 4–6 retesting market. | Local PPL/IR, cadet, LAT instructor. |
| 5 | **France** | Large GA + ULM; French ATC often in French → comprehension friction for foreign pilots and English-stream students. | Student at ENAC/cadet ATOs, foreign-flag PPL. |
| 6 | **Australia** | Large GA, English-native ATC, but high foreign-cadet inflow (Asia → Aus ATOs). | Asian cadet, regional CPL. |
| 7 | **New Zealand** | Disproportionately large ATO hub (Massey, CTC/L3, Air NZ). | International cadet. |

Tier 2 (high-WTP smaller markets — launch in same wave, just smaller volume):

| # | Country | Why it's in | Persona |
|---|---|---|---|
| 8 | **Netherlands** | High English proficiency, KLM Flight Academy, strong EFB adoption. | Cadet, PPL, instructor. |
| 9 | **Switzerland** | Very high WTP, alpine ops, Lufthansa-affiliated training, premium GA. | Premium PPL, IR, business aviation. |
| 10 | **Austria** | Adjacent to DE/CH, alpine ops, German-language ATC at some fields. | PPL, IR retraining. |
| 11 | **Sweden** | Strong GA, ATPL training (LFT, OSM), long-IFR culture. | Cadet, PPL, IR. |
| 12 | **Norway** | High-WTP, heavy heli/bush, Bardufoss/CAE Oslo training. | Heli pilot, cadet. |
| 13 | **Denmark** | Small but premium GA, CAE Copenhagen. | Cadet, PPL. |
| 14 | **Finland** | Small GA, Patria Pilot Training, strong English. | Cadet, PPL. |
| 15 | **Ireland** | Major ATO hub (Atlantic Flight Training Academy, FTE, AFTA), Ryanair MPL pipeline. | Cadet — *very high ICP fit*. |
| 16 | **Italy** | Large EU GA, mixed Italian/English ATC → strong friction. | PPL, IR, cadet. |
| 17 | **Spain** | Major ATO hub (FTEJerez, One Air, AeroClass), good weather → training capital of Europe. | Cadet, PPL. |

Tier 3 (premium niche, smaller pilot count but very high per-pilot WTP and pain):

| # | Country | Why it's in | Persona |
|---|---|---|---|
| 18 | **Japan** | High WTP, regulated GA, JAL/ANA cadet pipelines (often trained abroad in English), domestic ATC in English at international fields. | Cadet, airline crew refresher. |
| 19 | **South Korea** | High WTP, English-only ATC at major airports, large cadet exports to US/Aus. | Cadet, GA hobbyist. |
| 20 | **United Arab Emirates** | Hub for Emirates/Etihad/FlyDubai cadet programmes (Etihad Aviation Training, Emirates Flight Training Academy), very high WTP, Apple Pay/Stripe-mature. | Cadet, line pilot using app for comms refresher. |

**Why not included** (and what would change my mind):
- **CIS (RU/BY/UA/KZ/etc.):** explicitly excluded per directive. No-go.
- **China:** App Store enforcement + payments friction + ATC mostly Mandarin → wedge weak; revisit after international wedge proven.
- **India:** Big pilot pipeline, but low ARPU and price-sensitivity make hours packs hard to anchor; revisit when freemium tier exists.
- **Brazil / Mexico / Argentina / South Africa:** large GA but currency/payment friction and lower WTP — Tier 4, revisit after Tier 1+2 LTV proven.
- **Israel / Czech Republic / Belgium / Singapore / Hong Kong / Taiwan:** quality markets, just edged out by Tier 3 on either pilot-count or wedge-pain proxy. Promote into top 20 if Tier 3 underperforms.

> `[ASSUMPTION]` This 20-country ranking is anchored on widely-reported aviation training and GA-fleet structure, not on a freshly-pulled 2026 dataset. Source-gap TODOs in §11 list the specific pulls that would harden each rank.

---

## 2. Pricing model — hour packs + thin monthly + school/CFI seats

Andrei's idea ("платят за фактически использованное время, покупает пакеты часов") is correct because:

- Pilots already buy aircraft time, sim time, and CFI time by the hour — the unit is native.
- Hours of *captured cockpit audio* is a defensible meter (it's what costs us, regardless of whether ASR is on-device or cloud-fallback).
- A small monthly base avoids the "I paid $X for hours that expired" backlash and gives recurring revenue floor.

**Recommended unit-of-value:** "**Cockpit Hours**" — wall-clock hours during which Dspeech is in an active capture session (paused/idle time doesn't burn). Roll over up to 12 months after purchase. Buying a bigger pack discounts the per-hour rate.

### 2.1 Headline plans (USD, US/Tier 1 anchor)

| Plan | Audience | Price | Includes | Fences |
|---|---|---|---|---|
| **Free / Trial** | Anyone | $0 | 2 Cockpit Hours total, 14-day window, watermarked export | No multi-device, no offline translation pack |
| **Pilot Starter** (consumable pack) | Casual PPL / ESL pilot | **$24.99** one-time | 10 Cockpit Hours, expires 12 mo | Solo device, basic translation |
| **Pilot Pro** (subscription) | Active PPL/IR/cadet | **$19.99 / mo** or **$179 / yr** ($14.92/mo eq.) | 25 Cockpit Hours / mo (rollover up to 50), offline language packs, transcript export, debrief mode | Solo device, no team seats |
| **Pilot Unlimited** (subscription) | Heavy flyer, IR retraining | **$39.99 / mo** or **$359 / yr** ($29.92/mo eq.) | Soft-capped "unlimited" (fair-use 120 h/mo), priority ASR, all translation packs, advanced debrief | Solo device |
| **CFI / Instructor** | Independent CFI managing ≤10 students | **$49 / mo** or **$439 / yr** | 5 seats (1 CFI + up to 4 students), 80 Cockpit Hours pooled / mo, shared debrief & comment threads, ICAO English proficiency drill mode | Cannot resell |
| **Flight School Starter** | Small ATO, ≤25 students | **$249 / mo** or **$2,490 / yr** | 25 seats, 600 Cockpit Hours pooled, admin console, SSO via Apple/Google, anonymised cohort dashboards | LOI required for >25 seats |
| **Flight School Pro** | ATO with cadet programme | **Quote** | 50–500 seats, custom hours pool, multilingual translation packs, ICAO Level 4–6 prep curriculum hooks, SCIM, audit log | Annual commitment, LOI/MSA |

### 2.2 Add-on packs

- **Cockpit Hour top-up:** $4.99 / hour single, $19.99 / 5 h, $69.99 / 25 h, $119.99 / 50 h. Top-ups extend rollover by 12 mo from purchase.
- **Offline language pack** (per language family): $4.99 one-time per user. (Free on Pro/Unlimited/School.)
- **Debrief export bundle** (PDF + JSON + searchable transcript archive, post-flight): $2.99 / flight on Starter, included on Pro+.

### 2.3 Offer fences (what gates what)

| Capability | Free | Starter | Pro | Unlimited | CFI | School |
|---|---|---|---|---|---|---|
| Live ATC transcription | yes | yes | yes | yes | yes | yes |
| Receive-only intercom capture | yes | yes | yes | yes | yes | yes |
| Translation (live) | EN→1 lang | EN→1 | all langs | all | all | all |
| Original-audio canonical export | yes | yes | yes | yes | yes | yes |
| Debrief / post-flight review | view only | view+single export | full | full | full + shared | full + shared |
| Offline language packs | no | 1 | all | all | all | all |
| Multi-device sync (1 Apple ID) | no | no | yes (2) | yes (3) | yes (CFI+students) | yes (school) |
| Admin console / cohort dash | no | no | no | no | basic | full |
| ICAO English proficiency drill | no | no | preview | yes | yes | yes |
| Support SLA | community | 72 h | 24 h | 12 h | 12 h | 4 h business |

### 2.4 What we explicitly do **not** promise

These are non-negotiable disclaimers, repeated on landing, App Store description, in-app onboarding, AI bot persona, and TOS:

- **Not certified.** Dspeech is a supplemental, receive-only situational-awareness aid. **Original audio is canonical**; the transcript is best-effort.
- **No safety-of-flight reliance.** Pilots must never substitute Dspeech transcript for ATC readback, traffic awareness, or any operational task. Always read back from your own hearing.
- **No transmission.** Dspeech does not transmit on aviation frequencies and never will.
- **No guaranteed accuracy.** ASR will mishear; we publish replay-corpus benchmark numbers honestly rather than marketing claims.
- **No ICAO English certification.** We can drill, we cannot certify. State examiner is canonical.
- **No medical / mental-health claims** (e.g. for fatigue debrief). Pure tooling, not advice.
- **No legal/operational record-of-conversation.** Recording laws differ per jurisdiction; users are responsible for local compliance, especially in multi-pilot cockpits and during training.

---

## 3. Country-band PPP-adjusted price grid

Andrei's directive: **price each country to its market**, not to a single USD list. Below is a banding scheme so the App Store storefront strings stay manageable but pricing tracks local purchasing-power and competitor anchors.

| Band | Index vs US | Pilot Pro / mo | Pilot Unlimited / mo | CFI / mo | Countries (from §1) |
|---|---|---|---|---|---|
| **A (premium)** | 1.10× | $21.99 | $43.99 | $54 | CH, NO, JP, UAE |
| **B (US anchor)** | 1.00× | $19.99 | $39.99 | $49 | US, CA, AU, NZ, DK |
| **C (Western EU mainstream)** | 0.90× | €16.99 / £14.99 | €34.99 / £29.99 | €44 / £39 | UK, DE, FR, NL, SE, FI, IE, AT |
| **D (Southern EU + KR)** | 0.80× | €15.99 | €31.99 | €39 | IT, ES, KR |
| **E (Tier-4 reserve)** | 0.70× | (n/a Tier-1) | (n/a) | (n/a) | reserved for future Tier-4 (BR/MX/IN/ZA/TH/MY/CZ/PL) |

> `[ASSUMPTION]` Index vs US is set qualitatively from public ForeFlight/SkyDemon regional pricing patterns, App Store regional anchors, and OECD per-capita disposable-income deltas. Re-anchor after pulling current ForeFlight EU/UK price ladder and Apple's 2026 storefront price tier table (§11 TODO).

### 3.1 Hour-pack regional price (Starter and top-ups)

| Band | Starter 10 h | Top-up 5 h | Top-up 25 h | Top-up 50 h |
|---|---|---|---|---|
| A | $27.99 | $21.99 | $76.99 | $131.99 |
| B | $24.99 | $19.99 | $69.99 | $119.99 |
| C | €21.99 | €17.99 | €59.99 | €99.99 |
| D | €19.99 | €15.99 | €54.99 | €89.99 |

---

## 4. Comparable price anchors (the competitive map)

These are the prices a pilot/CFI/school already pays. Dspeech must be **cheaper than EFB Pro and roughly the price of a single sim hour**, not a luxury.

### 4.1 EFB / pilot apps (the obvious adjacents)

| Product | Tier | Price (USD, public end-2025) | Read-across for Dspeech |
|---|---|---|---|
| **ForeFlight Mobile Basic** | individual | ~$99.99/yr `[ASSUMPTION]` | Sets the floor for "pilot will pay annually." Pull current page (§11). |
| **ForeFlight Mobile Pro Plus** | individual | ~$199.99/yr `[ASSUMPTION]` | A pilot already pays $200/yr for one EFB without blinking. |
| **ForeFlight Performance Plus** | individual | ~$299.99/yr `[ASSUMPTION]` | Heavy-use pilots will pay $300/yr for a single tool. |
| **ForeFlight Business / MFB** | enterprise | $400+/yr per seat `[ASSUMPTION]` | Anchors school/enterprise SKU. |
| **Garmin Pilot Premium** | individual | ~$199.99/yr `[ASSUMPTION]` | Reinforces $200/yr ceiling for solo. |
| **SkyDemon (UK/EU)** | individual | ~£155–£175/yr `[ASSUMPTION]` | Anchors C-band annual. |
| **Jeppesen Mobile FliteDeck VFR/IFR** | individual | €150–€500/yr `[ASSUMPTION]` | Anchors C-band premium. |
| **FltPlan Go** | individual | free | Reminder: free EFBs exist; Dspeech can't be priced as if it competes on flight-planning. We do *not* compete with EFBs; we sit *next to* them. |

> Implication: Pilot Pro at $19.99/mo (≈$179/yr annual) is **below** ForeFlight Pro Plus and SkyDemon, so we never become the highest-line item in a pilot's app stack. Good. We can raise later.

### 4.2 Aviation radio / comms / English drill (closest functional adjacent)

| Product | Price `[ASSUMPTION]` until §11 verifies | Read-across |
|---|---|---|
| **PlaneEnglish ARSim** (radio-comms trainer) | ~$59 one-time + premium | Closest single-purpose competitor; pilots pay $60 happily. Justifies $24.99 Starter pack. |
| **Say Again Please** (book + drill courses) | $30–80 | Confirms WTP for ESL ATC drill. |
| **LiveATC.net Pro** | ~$2.99/mo | Floor for "ATC audio" willingness — but Dspeech delivers *understanding*, not just audio, so we sit 5–10× above. |
| **PilotEdge** (sim ATC) | ~$19.95/mo | Direct anchor for $19.99 Pro. |
| **Aviation English Asia** / **Latitude Aviation English** courses | $200–800 course | Anchors B2B-school/cohort pricing. |

### 4.3 Flight training / school software (B2B anchor for CFI & School SKUs)

| Product | Price `[ASSUMPTION]` | Read-across |
|---|---|---|
| **CloudAhoy** (debrief) | ~$10–30/mo individual; school tier custom | Anchors $19.99 Pro and validates debrief as a paid feature. |
| **King Schools** (PPL/IFR ground school) | $279–$499 one-time | High WTP for *course* products; Dspeech is a *tool* — must be cheaper. |
| **Sporty's Pilot Training app** | $99–299/course | Same. |
| **ATP Flight School zero-to-CFI** | ~$99,995 | Confirms school-budget headroom; $2,490/yr for a 25-seat plan is rounding error. |
| **Flight Schedule Pro / Flight Circle** (scheduling SaaS) | $5–15/seat/mo | Anchors per-seat school pricing. |

### 4.4 General transcription / debrief (the price-trap to avoid)

| Product | Price `[ASSUMPTION]` | Read-across |
|---|---|---|
| **Otter.ai Pro** | $16.99/mo | Dangerous anchor — a pilot may think "$17 for unlimited transcription, why pay for Dspeech?" We respond: aviation-domain ASR, callsign protection, offline cockpit operation, intercom-grade audio support. Don't position next to Otter; position next to ForeFlight + PlaneEnglish. |
| **Trint** | $80/mo | Way too high; never anchor here. |
| **Rev.com** | $0.25/min auto / $1.50/min human | Anchors top-up per-hour ceiling — 1 cockpit hour of human transcription = $90, so $4.99/h is a huge discount. |
| **Descript** | $24/mo | Reminder consumer transcribers exist; differentiate on domain. |

> Bottom line: Dspeech's correct comp set is **ForeFlight + PlaneEnglish + PilotEdge**, *not* Otter/Trint. Land all messaging there.

---

## 5. Landing page positioning (`dspeech.com`)

Build a one-page landing for v0; route to TestFlight + paid wait-list now, App Store later. Mobile-first; landscape video hero.

### 5.1 Page outline

1. **Above-the-fold hero** (≤ 5 s comprehension):
   - **H1:** "Hear every word from ATC."
   - **Subhead:** "Dspeech is a receive-only ATC and intercom transcription companion for iOS — built for pilots, CFIs, and flight schools. On-device first. Original audio always canonical."
   - **CTA:** "Get the TestFlight invite" (email gate → Mr.Dao-managed list) and "See how it works" (anchor to demo video).
   - **Trust strip:** "Receive-only · Supplemental only · No transmission · Your audio stays on your device by default."
2. **The pain** (3 ESL pilot quotes, anonymised; mark `[PLACEHOLDER]` until real LOIs arrive).
3. **How it works** (3 columns: capture → transcribe → review). Each column shows iPhone landscape screenshot.
4. **Who it's for** (cards: PPL/IR pilots, ATPL cadets, CFIs, flight schools). Each card → segment-specific landing later.
5. **Pricing block** (Starter / Pro / Unlimited / CFI / School), with "from $19.99/mo, 14-day free trial, 2 Cockpit Hours". Currency auto-detected.
6. **What Dspeech is NOT** (full disclaimer block — non-certified, supplemental, original audio canonical). This is a trust-builder, not a hide-away.
7. **FAQ** (≥ 12 Q's: certification, transmission, accuracy, languages, data privacy, offline, intercom hardware compatibility, refunds, recording-law jurisdictions, ICAO Level prep, sharing with CFI, export formats).
8. **Footer:** legal, privacy, contact, social, blog, GitHub status (link to public roadmap if/when one ships).

### 5.2 Conversion stack (technical)

- **Stack:** Static Next.js or Astro on Vercel/Cloudflare Pages; form posts to Hermes endpoint → Notion DB + email confirmation.
- **Analytics:** PostHog or Plausible, GDPR-respecting; no Meta/TikTok pixels in v0 (add only when paid ads turn on, and only with consent banner).
- **A/B harness:** server-side flag for headline & hero video, 1 variant at a time, ≥ 100 unique visits per arm before judging.

### 5.3 LOI / closed-beta wording (paste-ready)

> "I'm interested in piloting Dspeech with my flight school / CFI practice. I understand Dspeech is a supplemental, receive-only situational-awareness aid — original audio remains canonical, and Dspeech is not certified for any operational use. I'd like to receive a TestFlight invite, and I'm open to discussing a pre-paid annual seat plan once the closed beta meets the accuracy bar I need."

Signed by name + role + school + email. No money collected until accuracy bar agreed.

---

## 6. App Store listing outline

(Not for submission yet — staged for the App Store agent to pick up later.)

- **Name:** Dspeech — ATC Transcribe & Translate
- **Subtitle (≤ 30 ch):** "Pilot ATC & intercom aid"
- **Promotional text:** "Receive-only iOS transcription for pilots and flight schools. Supplemental only. Original audio canonical."
- **Description:** lead with disclaimer block + value bullets + persona scenarios + offline/privacy + pricing summary + support + non-promises. Keep keyword density natural; let ASO agent harden later.
- **Keywords:** atc, transcription, pilot, flight school, cfi, aviation english, icao level 4, intercom, debrief, atpl, ppl, ifr — `[ASSUMPTION]` final keyword set after ASO pull (§11).
- **Screenshots:** landscape iPhone 17 Pro, iPad 13"; six frames: live transcript, translation, debrief, ICAO drill, CFI dashboard, "what Dspeech isn't" disclaimer slide. The disclaimer slide is *deliberate* — reduces 1-star reviews from misuse.
- **Privacy nutrition:** audio collected on-device by default; if cloud fallback enabled, audio sent to vendor-of-record only for the session, not retained.
- **Age rating:** 4+.
- **In-app purchases:** auto-renew Pro/Unlimited/CFI/School + consumable hour packs.
- **Region:** initial release in the 20 countries from §1 (excluding any with App Store/payment friction we discover during submission). Stage in 5-country waves; instrument funnel before scaling.

---

## 7. Social content & paid-ad experiment plan (draft only — no spend)

### 7.1 Channels & posture

- **Instagram** (Reels + carousels): primary, pilot demographics are very active.
- **TikTok**: secondary, younger cadet audience; aviation-niche is small but engaged.
- **YouTube Shorts** + **long-form**: long-form (~10 min) for "how to use Dspeech for ICAO Level 4 prep" SEO captures cadets searching English-aviation help; Shorts for top-of-funnel.

### 7.2 Content pillars (rotation)

1. **"Did you hear that?"** — real (cleared-for-use) cockpit clip + live Dspeech transcript overlay; pause-and-quiz.
2. **ESL cadet stories** — anonymised CFI quotes, "before/after Dspeech for ICAO Level 4 prep".
3. **What Dspeech *isn't*** — disclaimers as content (this is counter-intuitive but builds aviation-community trust; gatekeepers reward it).
4. **Behind-the-scenes** — on-device ASR benchmark replay corpus, latency demos, transparency about misheard callsigns.
5. **CFI tools** — debrief-mode + cohort dashboard demos.
6. **Translation in cockpit** — non-English ATC clip → live English transcript; explicit "original audio canonical" overlay.

### 7.3 Posting cadence (organic only — no spend at first)

- 4–6 Reels/Shorts/TikToks per week, cross-posted with platform-native cut variants.
- 1 YouTube long-form / fortnight.
- 2 IG carousels / week (anchor SEO and bookmarkable).
- All posts: end-card with "TestFlight invite at dspeech.com".

### 7.4 Paid-ad experiment plan (draft — DO NOT SPEND until approved)

When paid is approved (later phase), the first six experiments to run, each as one-week, fixed micro-budget (`[ASSUMPTION] $50–100/day max`):

1. **IG Reels — Country-band B (US/CA/AU)** — best 3 organic-winning Reels; promoted to pilots 18–55, aviation interest. Hypothesis: CTR ≥ 1.5%, CPI ≤ $4, landing CVR ≥ 5%.
2. **TikTok Spark Ads — Country-band C (UK/DE/FR/IT/ES/NL)** — boost the highest-organic ESL cadet content; multilingual subtitles.
3. **YouTube in-stream — Country-band A (CH/JP/UAE)** — premium 15 s pre-roll, target aviation training channels.
4. **Reddit r/flying + r/aviation** — promoted post, *not* native ad, transparent "we built this, AMA" tone.
5. **Google Search** — keywords "ICAO Level 4 prep", "ATC English transcription", "flight school debrief tool".
6. **Quora / Stack Exchange Aviation** — organic, no spend; included as cheap content arm.

Kill criteria for each: CPI > 2× target, CVR < 50% of target, or trust-flag (negative comment cluster).

---

## 8. AI sales & support bot (Hermes) — architecture

This is the build that ties Andrei's "Продажи через ИИ чатбота" comment into shipping form. Mr.Dao/Hermes is the orchestration backbone; the sales/support bot is a new Hermes agent persona (`dspeech-concierge`).

### 8.1 Surfaces (where it can live, in priority)

| Surface | Why | When to ship |
|---|---|---|
| **Site widget on `dspeech.com`** | Captures the pre-sale question; closes trial signup. | v0 launch. |
| **In-app help panel (iOS)** | Catches activation/configuration friction. | v0.2. |
| **Instagram DM** (Meta Business API) | Where ESL pilots already ask questions. | v0.3 (needs Meta approval). |
| **WhatsApp Business** | High-engagement in DE/FR/IT/ES/UAE. | v0.3. |
| **Telegram** | High-engagement among many non-CIS cadet communities; geo-gated intake so we never *market* into CIS. | v0.3 (geo-gated). |
| **Email (dedicated inbox)** | Long-form / B2B / school RFI handler. | v0 (basic). |

### 8.2 Qualification flow

The bot's first job is **qualify**, second job is **answer**, third job is **handoff**.

```
[user opens chat]
  ↓
1. Identify role: PPL / IR / cadet / CFI / school admin / curious / press / press-not-pilot
  ↓
2. Identify country + ICAO English level (self-report, optional)
  ↓
3. Identify intent: information / trial / quote / support / partnership / hiring
  ↓
4. Match to playbook:
     - info → answer from doc-grounded RAG (landing-page + FAQ corpus)
     - trial → TestFlight invite + Stripe pre-pay (if Starter pack)
     - quote → CFI/School playbook; auto-draft LOI, escalate to human
     - support → create ticket (see §8.4)
     - partnership/press → escalate to human, no autonomous reply
     - hiring → polite redirect, no autonomous reply
  ↓
5. Always end: explicit disclaimer + invite to escalate to human.
```

### 8.3 Persona & safety rails

- **Persona:** "Dspeech Concierge" — concise, factual, aviation-literate, never enthusiastic, never marketing-toned. Tone closer to ATC than to consumer chatbot. Always uses original-audio-canonical wording.
- **Hard-coded refusals**:
  - No claims of certification, safety-of-flight, ICAO licensing, accuracy guarantees beyond benchmark numbers.
  - No medical/mental-health advice.
  - No legal advice on recording laws — directs to local CAA/lawyer.
  - No competitor disparagement.
  - No autonomous billing actions beyond Stripe-link generation; refunds and plan changes go to human.
- **OWASP LLM Top-10 mitigations** (per global security rules):
  - All tool calls scoped to read-only on RAG corpus + one write tool (`create_support_ticket`); no shell, no DB write, no email-send-as-user.
  - Indirect prompt-injection isolation: any external content (uploaded transcripts, attached audio metadata) is *quoted, never executed as instruction*.
  - Output handling: bot responses HTML-escaped on render; never rendered as Markdown into a SQL/email pipeline.
- **Logging:** every bot turn logged to Hermes with hash-anchored session ID; PII minimised (no audio uploaded by default; if uploaded for support, retained 30 d and deleted).

### 8.4 Support ticket handoff

- Ticketing surface: lightweight, lives in **Notion** initially (DB: `Dspeech Support`), graduates to **Linear** when ticket volume > 50/week.
- Bot creates ticket with: user email, role, country, plan, build version, device, summary, transcript of last N bot turns, severity (`bug` / `billing` / `safety-concern` / `feature-request` / `school-RFI`).
- **CRM boundary:** No HubSpot/Salesforce in v0. Notion table is the CRM. School RFIs flagged for human follow-up.
- **Severity ladder**:
  - `safety-concern` → page Andrei + freeze auto-replies on that session.
  - `billing` → auto-reply only with policy text; resolution by human.
  - `bug`/`feature` → triaged into the iOS mobile agent's backlog; bot replies with ticket ID.
- **Disclaimers in every reply:** "I'm an AI. Dspeech is a supplemental, receive-only aid. Original audio is canonical."

### 8.5 RAG corpus seed (first 30 docs)

- This memo (`docs/product/2026-05-18-pricing-launch-memo.md`)
- `README.md` + `docs/architecture.md`
- Disclaimer block (canonical text, versioned)
- FAQ (12 entries from §5.1)
- Pricing tables (§2–§3)
- Country-band rules (§3)
- Comparable anchor list (§4)
- App Store listing (§6)
- Hermes agent persona spec (§8.3)
- Severity policy (§8.4)
- Refund policy `[TODO]`
- Privacy policy `[TODO]`
- TOS `[TODO]`

> Corpus must be versioned in `docs/product/` and reviewed every change; bot must refuse if asked about anything not in corpus.

---

## 9. Recommended go-to-market sequence

(Build sequencing only — no time estimates, per global rules.)

1. **Repo:** mobile agent finishes capture spike + replay-corpus benchmark on its own branch; product agent (this branch) lands this memo + FAQ doc + disclaimer doc + LOI template.
2. **Domain & landing:** Static landing on `dspeech.com` from §5; Hermes intake endpoint; closed wait-list.
3. **TestFlight closed beta:** 20–50 invited pilots/CFIs across Tier-1+2; collect accuracy + UX signal; no paid charge yet.
4. **Pricing flip-on:** Stripe pre-pay for Starter pack + Pro monthly; LOI for School; reversible refunds; still no App Store listing.
5. **Hermes Concierge v0:** site widget only; RAG corpus from §8.5; human-in-loop on every school RFI.
6. **Social content engine:** 4–6 organic posts/week from §7.2; measure CVR-to-wait-list.
7. **App Store submission:** when accuracy bar + crash-free rate + disclaimer review pass; stage in 5-country waves from §1.
8. **Paid experiments:** only after organic CVR > X% on the wait-list; run §7.4 experiment menu.
9. **CFI + School pilot:** convert top 3 LOIs into paying schools; iterate cohort dashboard.
10. **Revenue checkpoint:** evaluate whether $20k/mo trajectory is achievable on current ARPU & funnel; if not, identify which lever (price / market mix / channel / persona) underperformed and revise.

---

## 10. Open product decisions for Andrei (binary, fast)

These need a yes/no from Andrei before downstream agents can move:

1. **Currency strategy:** local-currency bands (§3) — **yes/no**?
2. **Cockpit Hour as unit-of-value** (§2) — **yes/no**? (If "no", default to seat-time monthly only.)
3. **Free tier ships at launch** (2 h + 14 d) — **yes/no**? (Risk: free-trial abuse; benefit: lower CAC.)
4. **Closed-beta charges money before App Store listing** (Stripe pre-pay LOI'd Starter packs) — **yes/no**?
5. **Concierge bot ships on site only at v0** (vs IG DM at launch) — **yes/no**?
6. **Telegram surface** for the bot — **yes/no** given CIS-exclusion rule? (Recommendation: **yes, but geo-gated** — Telegram is non-CIS-exclusive; geo-restrict the bot's intake form to the 20 countries.)
7. **Schools billed in USD or local** — **yes/no** local?
8. **ICAO English drill mode** as a paid differentiator — **yes/no**?

---

## 11. Source-gap TODOs (verification before pricing locks)

Each TODO is a concrete pull. None block this memo's circulation, but **all must be verified before pricing strings land in App Store Connect or in landing-page copy.**

- [ ] **AOPA active-pilot count 2025**, US — to anchor §1 rank #1. https://www.aopa.org
- [ ] **EASA Annex 1 pilot stock by member state 2024–2025** — to anchor §1 ranks 3–17. https://www.easa.europa.eu
- [ ] **UK CAA pilot licence stock latest** — §1 rank 3. https://www.caa.co.uk
- [ ] **Transport Canada CADORS / licence stats** — §1 rank 2. https://tc.canada.ca
- [ ] **CASA Australia pilot licence stats** — §1 rank 6. https://www.casa.gov.au
- [ ] **CAA New Zealand licence stock** — §1 rank 7. https://www.aviation.govt.nz
- [ ] **JCAB Japan licence stock** — §1 rank 18. https://www.mlit.go.jp/koku
- [ ] **MOLIT Korea licence stock** — §1 rank 19. https://www.molit.go.kr
- [ ] **GCAA UAE licence stock** — §1 rank 20. https://www.gcaa.gov.ae
- [ ] **ForeFlight current Mobile pricing page** (Basic / Pro / Pro Plus / Performance Plus / Business) — re-confirm §4.1 numbers. https://foreflight.com/products/foreflight-mobile/pricing
- [ ] **Garmin Pilot current pricing** — §4.1. https://www.garmin.com/en-US/p/115856
- [ ] **SkyDemon current annual price (UK + EU)** — §4.1. https://www.skydemon.aero
- [ ] **Jeppesen FliteDeck VFR/IFR current pricing** — §4.1. https://ww2.jeppesen.com
- [ ] **PlaneEnglish ARSim current pricing** — §4.2. https://planeenglishsim.com
- [ ] **PilotEdge current pricing** — §4.2. https://www.pilotedge.net
- [ ] **CloudAhoy / ForeFlight-Acquisition status + pricing** — §4.3. https://www.cloudahoy.com
- [ ] **Apple App Store regional price tier table 2026** — to lock §3 bands to Apple's storefront tiers. https://developer.apple.com/help/app-store-connect/reference/app-store-pricing-and-availability/
- [ ] **OECD per-capita disposable income 2024–2025** — to harden §3 PPP index. https://data-explorer.oecd.org
- [ ] **ICAO English proficiency requirement enforcement table** — to harden §1 column C. https://www.icao.int
- [ ] **Otter.ai / Rev.com / Trint / Descript current pricing** — §4.4.
- [ ] **Stripe + Apple Pay availability per Tier-3 country** — confirm UAE/JP/KR storefront-payments coverage.
- [ ] **Meta Business API + WhatsApp Business approval prerequisites** — §8.1.
- [ ] **Refund / Privacy / TOS drafts** — §8.5 corpus.

When the doc-research agent runs, it should pull these in parallel, write each result with quoted source + date-fetched, and update the relevant section here in-place. This memo is versioned in git so updates are auditable.

---

## 12. Envelope for orchestrator

(Returned separately in the Mr.Dao reply; included here for archival.)

- `status: partial`
- `summary:` First-pass pricing & launch memo committed to `feat/product-pricing-memo` worktree on `dspeech` repo at `docs/product/2026-05-18-pricing-launch-memo.md`. Covers 20-market list (CIS-excluded), Cockpit-Hours pricing model (Free/Starter/Pro/Unlimited/CFI/School + PPP bands), comparable anchors (ForeFlight/SkyDemon/PlaneEnglish/PilotEdge/Otter), landing-page & App Store outlines, Instagram/TikTok/YouTube content pillars + draft (no-spend) paid plan, and Hermes Concierge sales/support bot architecture. Pricing bands and competitor prices are labelled `[ASSUMPTION]` pending §11 source pulls; no facts invented as verified.
- `evidence:` `dspeech@feat/product-pricing-memo`, `docs/product/2026-05-18-pricing-launch-memo.md`, see §11 for source list.
- `next_steps:` (1) Andrei answers §10 binary decisions. (2) Dispatch doc-research agent to clear §11 TODOs. (3) Dispatch landing-page agent (separate branch) to scaffold `dspeech.com` per §5. (4) Dispatch Hermes-bot agent to prototype Concierge per §8 on `MyInfra/Hermes_*`. (5) Mobile agent continues on its own branch; this branch never collides with `Dspeech/`, `Dspeech.xcodeproj`, or `docs/architecture.md`.
