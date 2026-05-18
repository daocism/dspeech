# Mission report — 2026-05-18 (B) Notion tails batch

Source: Mr.Dao dispatch 2026-05-18T15:15+02:00 — close out pending Dspeech bullets in Andrei's "Осталось сделать" spoiler.

## Status

`done` (docs-only; no code change).

## Pending bullets → artifact

| Bullet | Artifact(s) | Andrei action required? |
|---|---|---|
| ASR benchmark | `docs/eval/asr-benchmark-plan.md` | yes — approve LiveATC ingestion + physical-device benchmark window |
| Translation MT benchmark | `docs/eval/translation-benchmark-plan.md` | yes — translator budget + initial target langs |
| Terminology guard | `docs/eval/terminology-guard-spec.md` | yes — review glossary v1, confirm verbatim-English policy |
| Audio input matrix | `docs/eval/audio-input-matrix.md` | yes — confirm owned wired adapters / panel make |
| Evaluation corpus | `docs/eval/evaluation-corpus-spec.md` | yes — corpus storage backend + transcriber decision |
| PRD iOS MVP w/ translation toggle | `docs/product/prd-ios-mvp.md` | no — read & comment is enough |
| Language-pack / download spec | `docs/product/language-pack-spec.md` | yes — `packs.dspeech.app` domain + initial pairs |
| Cloud fallback cost/privacy matrix | `docs/product/cloud-fallback-matrix.md` | yes — pick first cloud ASR + MT vendor, sign DPAs |
| Regulatory / privacy memo | `docs/product/regulatory-privacy-memo.md` | yes — engage privacy counsel, decide on legal entity, register dspeech.app |
| Competitor teardown | `docs/product/competitor-teardown.md` | optional — confirm priority competitors to monitor |

Zero bullets remain uncovered. Every bullet either fully closed (PRD, competitor) or has a concrete spec + a delineated Andrei-action queue listed below.

## Andrei action queue (consolidated, step-by-step)

Do these in the listed order; each step is independent and can be done in one sitting.

1. **Read `docs/product/prd-ios-mvp.md` and reply with a thumbs-up or specific changes.** This unblocks the engineering slice (it pins functional acceptance F1–F8).
2. **Decide corpus storage backend** (S3 / NAS / encrypted external drive). Tell Mr.Dao the choice; Claude wires it.
3. **Decide on a part-time aviation-literate transcriber.** Two options:
   - (a) Andrei transcribes 22 h himself across 3–4 weekends.
   - (b) Hire (Upwork / Fiverr) — budget anchor ≈ $15–$25/h × 22 h ≈ $330–$550 USD for transcription + QA pass.
   Tell Mr.Dao which option; if (b), authorize budget.
4. **Approve LiveATC / YouTube ATC clip ingestion** for internal eval use (read `docs/eval/evaluation-corpus-spec.md` "Source buckets" + "Privacy / legal posture"). Simple yes/no.
5. **Approve physical-device benchmark on your iPhone 15** — ≈ 2 h, screen on, will drain battery once. Schedule a slot.
6. **Decide initial top-3 target languages** for translation. Working proposal: RU, ES, EN (source-only). Tell Mr.Dao if different.
7. **Confirm/own `dspeech.app` and `packs.dspeech.app`.** Register at Cloudflare/Namecheap if not yet; if owned, tell Mr.Dao the registrar and Claude updates the deploy plan.
8. **Decide first cloud-ASR + cloud-MT vendor** (only if/when we ever flip the cloud path on). Proposal: Deepgram nova-3 + DeepL Pro. Read `docs/product/cloud-fallback-matrix.md`; respond yes/no/other.
9. **Engage privacy counsel** before public App Store launch. EU + US privacy lawyer; light scope (Privacy Policy + DPA review). Can be deferred until cloud opt-in is actually enabled, but identify the lawyer now.
10. **Decide legal entity** to act as data controller for cloud-opt-in users (relevant if EU users will ever enable cloud). Existing entity ok? Need to incorporate? — tell Mr.Dao.

Items 1–6 unblock engineering. Items 7–10 unblock public launch.

## What was NOT done in this dispatch

- No code change (none required).
- No App Store submission, no outreach, no hardware buying, no domain registration, no cloud path enabled. (Per dispatch guardrails.)
- No actual benchmark runs — only the plan for them. Runs require corpus first (item 2 + 3 + 4 above).

## Verification

- `git status` clean after commit.
- `xcodebuild test` not re-run this dispatch (zero Swift / pbxproj changes; previous green run at `3da67c0` stands).
- Grep check: all 10 new docs cross-reference each other consistently (manual scan).

## Notion mirroring required

Mr.Dao should attach the file paths to the Notion `🤖 Mr.Dao — осталось сделать` spoiler line items:

- ASR benchmark → `docs/eval/asr-benchmark-plan.md`
- translation MT benchmark → `docs/eval/translation-benchmark-plan.md`
- terminology guard → `docs/eval/terminology-guard-spec.md`
- audio input matrix → `docs/eval/audio-input-matrix.md`
- evaluation corpus → `docs/eval/evaluation-corpus-spec.md`
- PRD iOS MVP с переводом → `docs/product/prd-ios-mvp.md`
- language-pack/download → `docs/product/language-pack-spec.md`
- cloud fallback cost/privacy → `docs/product/cloud-fallback-matrix.md`
- regulatory/privacy memo → `docs/product/regulatory-privacy-memo.md`
- competitor teardown → `docs/product/competitor-teardown.md`

## Residual risk

- Pricing/cost anchors in cloud-fallback-matrix and competitor-teardown are public-list as of 2026-05-18 and will drift; re-verify before any external claim.
- Pack signing key (`dspeech-pack-key-2026`) referenced in `language-pack-spec.md` doesn't exist yet — generate when first pack ships.
- Pack-catalog domain `packs.dspeech.app` not yet owned.
