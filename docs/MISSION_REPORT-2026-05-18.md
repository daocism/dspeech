# Mission report — 2026-05-18 Notion task batch

Source: Andrei comments on Notion DB, relayed via Mr.Dao 2026-05-18T13:45+02:00.

## Status

`done`

## Final state

- Branch: `main`
- HEAD: `3da67c0`
- Build: xcodebuild on mac24 (iPhone 17 Pro Simulator, iOS 26.4): `** TEST SUCCEEDED **`
- Tests: DspeechTests 9/9 PASS, DspeechUITests 3/3 PASS

## Decisions captured (Andrei → repo artifact)

| Notion page | Decision | Artifact |
|---|---|---|
| 360dfa…be4950 (privacy) | local-only by default | ADR 0002, `Dspeech/Core/Settings/PrivacySettings.swift`, Settings UI |
| 360dfa…f524a3c8c0d0 (validation) | app first, cabin tests later | ADR 0005 |
| 360dfa…f8a40d (hardware) | no buys, wired-only | ADR 0004 |
| 361dfa…f9a48 (pricing) | top-20 dev aviation, no CIS | `docs/product/pricing-top20-aviation.md` |
| 361dfa…dadf87c500c4 (paid beta) | hour-bundle packages | ADR 0003, `docs/product/hourly-package-model.md` |
| 361dfa…c56e67af8f56 (sales) | landing + App Store + IG/TT/YT shorts + Hermes AI bot, no call script | ADR 0006, `docs/product/launch-positioning.md`, `docs/product/hermes-sales-bot.md` |

## Files changed in this dispatch

Engineering (Swift / pbxproj):

- `Dspeech.xcodeproj/project.pbxproj` — registered `PrivacySettings.swift` + `PrivacySettingsTests.swift` into the build phases (Settings group under Core).
- `Dspeech/App/ContentView.swift` — `PrivacyBadge` consumes `privacy.mode`; SettingsView wired with Privacy section + cloud-opt-in toggle.
- `Dspeech/Core/Settings/PrivacySettings.swift` — `@unchecked Sendable` on `UserDefaultsPrivacySettingsStorage` to satisfy Swift 6 strict concurrency (UserDefaults is documented thread-safe).
- `DspeechTests/PrivacySettingsTests.swift` — 7 unit tests for storage round-trip, default mode, allow-cloud toggle, badge text.
- `DspeechUITests/DspeechUITests.swift` — added `testPrivacyBadgeStartsLocalAndFlipsToCloudOnOptIn` driven by `-dspeech.privacy.mode.v1` launch arg + coordinate-tap on the Form Toggle.

Docs / strategy:

- `docs/PLAN-2026-05-18.md`
- `docs/MISSION_REPORT-2026-05-18.md` (this file)
- `docs/adr/0002-privacy-local-only-default.md`
- `docs/adr/0003-monetization-hour-packages.md`
- `docs/adr/0004-no-hardware-purchase-cable-testing.md`
- `docs/adr/0005-app-first-cockpit-validation-later.md`
- `docs/adr/0006-go-to-market-no-call-script.md`
- `docs/product/pricing-top20-aviation.md`
- `docs/product/hourly-package-model.md`
- `docs/product/launch-positioning.md`
- `docs/product/hermes-sales-bot.md`
- `AGENTS.md`, `CLAUDE.md` (repo-level AI guidance)

## What was NOT done in this dispatch (drafts only, by design)

- No App Store submission, no listing generated in App Store Connect.
- No landing page created or domain configured.
- No IG/TikTok/YouTube account created.
- No ads run, no money spent.
- No outreach to pilots, schools, or airlines.
- No hardware purchased (per Andrei).
- StoreKit 2 hour-pack implementation not built (spec only); Hermes sales bot not implemented (concept only).

## Residual risks

- Pricing tier numbers in `pricing-top20-aviation.md` are list anchors only; Apple's App Store tier matrix is binding at submission and will require resnap.
- UI test relies on `dspeech.privacy.mode.v1` launch-arg setting `UserDefaults`; if the storage key ever changes, the test silently drops back to default (test passes for the wrong reason). Documented as a fragility.
- Concurrent-agent edit storms were observed during this dispatch; final state is consistent but a stricter single-writer convention should be set for the next dispatch.

## Notion mirroring required by Mr.Dao

Mr.Dao should attach the following repo paths to each Notion task page (or paste the doc content as a comment):

- Page `360dfa2b-7893-8153-a062-ed6808be4950` → `docs/adr/0002-privacy-local-only-default.md`
- Page `360dfa2b-7893-8162-bb09-f524a3c8c0d0` → `docs/adr/0005-app-first-cockpit-validation-later.md`
- Page `360dfa2b-7893-8162-9eef-e5efb1f8a40d` → `docs/adr/0004-no-hardware-purchase-cable-testing.md`
- Page `361dfa2b-7893-81fc-9f76-c118f9b9fa48` → `docs/product/pricing-top20-aviation.md`
- Page `361dfa2b-7893-810b-a653-dadf87c500c4` → `docs/adr/0003-monetization-hour-packages.md` + `docs/product/hourly-package-model.md`
- Page `361dfa2b-7893-81c4-a412-c56e67af8f56` → `docs/adr/0006-go-to-market-no-call-script.md` + `docs/product/launch-positioning.md` + `docs/product/hermes-sales-bot.md`

## Next-step engineering candidates (NOT executed this dispatch)

1. Wire the `PrivacyMode` value through the future ASR/translation adapter factories so that the type system makes "cloud egress in `.localOnly`" unrepresentable.
2. Implement the hour-pack `Wallet` + `Meter` per `hourly-package-model.md` (StoreKit 2, monotonic seconds journal).
3. Replay-file ingestion path so ASR benchmarks are reproducible without aircraft hardware (per ADR 0004 + existing `docs/architecture.md`).
4. Build the `dspeech-landing` repo skeleton (Next.js 15 + MDX on Cloudflare Pages) without publishing.
