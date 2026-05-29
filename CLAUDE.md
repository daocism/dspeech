# Dspeech — Repo-level Claude/AI guidance

Auto-loaded when Claude works inside this repo. Sits on top of global user rules.

## What this repo is

Native iOS app. SwiftUI, Swift 6 strict concurrency, iOS 26+, Xcode 26. Domain: aviation cockpit / ATC transcription + optional translation. Receive-only.

Key context first:
- Plan / decisions for current iteration: `docs/PLAN-2026-05-18.md`.
- ADRs: `docs/adr/` (0001 iOS-first/local-first, 0002 privacy, 0003 monetization-hours, 0004 hardware, 0005 app-first sequencing, 0006 GTM).
- Product surfaces: `docs/product/` (pricing, launch positioning, hourly-package model, Hermes sales-bot concept).

## Hard rules (violation breaks the product, not just style)

1. **Local-only is the default.** `PrivacyMode.localOnly` is what a fresh install gets. No code path may ship audio, transcripts, or metadata off-device when `privacy.allowCloud == false`. See ADR 0002.
2. **No fake cloud / fake AI / fake transcription.** Don't add a `cloudASRClient` stub that pretends to call a server, or chat UI that pretends an AI is connected. Either wire it or don't ship the surface.
3. **No placeholders pretending functionality.** Stale work markers (the kebab-case to-do / fix-me tags), `unimplemented`-style panic primitives, "Coming soon" buttons, and demo screens that imply real product behavior are out. The transcript demo data is explicitly labeled `.demo` in `TranscriptSegment.Source` and is the only allowed exception until a real ASR adapter ships. Acceptance: `git grep -nE 'T<O>DO|FI<X>ME|fatal<E>rror\('` (without the angle brackets) must stay empty on the branch — written here with angle-bracket disguises so this rule itself never trips it.
4. **Privacy mode is visible at all times.** The `LOCAL` / `CLOUD` badge on the main control bar is not optional. Removing or hiding it requires a new ADR overriding ADR 0002.
5. **No hardware promises** in code, README, or store copy that haven't been tested on the wired/cable path. See ADR 0004.
6. **No App Store submission, no ads, no outbound DMs** from this repo's CI or scripts without explicit Andrei sign-off. See ADR 0006.
7. **No billing / StoreKit / pricing UI** until the implementation ADR for ADR 0003 / `docs/product/hourly-package-model.md` is written.
8. **No CIS regions** in price grids, region availability, or marketing region lists. See `docs/product/pricing-top20-aviation.md`.

## Architectural defaults

- SwiftUI views own no I/O. Services (`AudioCaptureService`, `SpeechRecognitionService`, future `TranslationService`, future `UsageMeter`) are `protocol` first, struct/class implementations second.
- State models are `@MainActor @Observable`. Injected storage protocols for anything persisted. `PrivacySettings` + `PrivacySettingsStorage` (in `Dspeech/Core/Settings/`) is the template.
- Tests: domain logic in Swift Testing (`@Test`); UI smoke in XCTest/XCUITest. New persistent settings get round-trip tests (see `PrivacySettingsTests.userDefaultsRoundTrip`).
- Accessibility identifiers are mandatory for any UI element a XCUITest needs to target. Use `accessibilityIdentifier("kebab-case")`, separate from `accessibilityLabel` (which can be localized prose).

## Build & test

On mac24 directly:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Dspeech.xcodeproj -scheme Dspeech \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  CODE_SIGNING_ALLOWED=NO build test
```

From ubuntu-vm (no Xcode locally), trigger over SSH:

```bash
ssh mac24 'cd /Users/andre/projects/dspeech-ios && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Dspeech.xcodeproj -scheme Dspeech \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
    CODE_SIGNING_ALLOWED=NO build test'
```

## File-layout conventions

- `Dspeech/App/` — SwiftUI scenes, views, view models, view-scoped state.
- `Dspeech/Core/Models/` — domain value types (`Equatable`, `Sendable`).
- `Dspeech/Core/Settings/` — persistent settings models + storage protocols.
- `Dspeech/Core/Audio/`, `Dspeech/Core/ASR/` — capture and recognition contracts; adapters live in subfolders when they arrive.
- `DspeechTests/` — Swift Testing target for domain.
- `DspeechUITests/` — XCUITest target for UI smoke.
- `docs/adr/` — Architecture Decision Records, numbered, append-only.
- `docs/product/` — product PRD and adjacent product docs.

## Project Workspace memory

This repo is the canonical Dspeech project memory for AI agents. Before non-trivial Dspeech work, read:

- `docs/ai-kb/README.md`
- `docs/ai-kb/current-context.md`
- `.ai/project-state.md`
- relevant ADRs under `docs/adr/`

Do not store Dspeech-scoped knowledge in global Mr.Dao/Claude memory. If work changes durable project truth, update `docs/ai-kb/current-context.md` and/or an ADR in the same branch. Notion is a read model only.

## Workflow

1. Read `docs/PLAN-<date>.md` (most recent) and the relevant ADRs first.
2. Branch per feature: `feat/<name>`, `fix/<name>`. Don't push directly to `main` for non-trivial work.
3. Before commit: run xcodebuild build+test green. Failing build = no commit.
4. ADR-worthy decisions get an ADR in `docs/adr/` in the same branch as the code that implements them.
5. Commit messages: conventional commits. Co-author Claude.

## What you may NOT do without asking Andrei

- Buy hardware (any).
- Submit / update App Store metadata.
- Run ads, outbound DM, or any paid acquisition.
- Add cloud-network code paths.
- Add billing / IAP / StoreKit code.
- Touch `Dspeech.xcodeproj/project.pbxproj` IDs that already exist (creating new file entries by appending is fine; renumbering existing ones is not).
