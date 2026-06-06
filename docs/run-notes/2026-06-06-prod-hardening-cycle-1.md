# Prod hardening — Cycle 1: kill the red-CI UI-test flake blocker

Date: 2026-06-06
Branch: `fix/review-hardening-2026-06-03`
Base HEAD before work: `bca0178187dfa05d2c6017137131343ea8732cdc`

## Blocker addressed

GitHub CI run `27004340215` (commit `bca0178`) was red **only** at the `Report test flakes`
step: `Build and test` itself passed *after retries*. Three XCUITests failed their first
attempt, then passed on retry, so the flake report (FLAKE_THRESHOLD=0) correctly failed the job:

1. `AccessibilityAuditUITests.testMainFailureState_errorBannerNotObscured()`
2. `DspeechUITests.testCorruptModelPackStateShowsContinueWithoutPath()`
3. `DspeechUITests.testVoiceFilterModelPackDownloadCTAIsEnabledAndStartsAcquisition()`

Hard constraints honored: did **not** raise `FLAKE_THRESHOLD`, did **not** skip/suppress the
accessibility audit, did **not** add more retries to hide the failures. Flake report stays a
strict *detector* (threshold 0).

## Root cause

Two independent flake sources, both first-attempt-only:

1. **Cross-suite CPU contention.** `ci.yml` ran unit + UI/a11y in one `xcodebuild build test`
   invocation. The CPU-heavy real-audio `DspeechTests` run in parallel with the XCUITests on a
   single hosted runner/simulator; under that contention (plus cold-simulator startup) UI queries
   intermittently timed out on the first attempt and recovered on retry.
2. **App never reaching idle + interacting before hittable.**
   - The idle Start button runs a decorative `repeatForever` glow animation
     (`ContentView.swift` `StartButton`). An infinite animation keeps the run loop perpetually
     "busy", which intermittently destabilizes `performAccessibilityAudit` and element queries.
   - `testMainFailureState_errorBannerNotObscured` ignored the `error-banner` `waitForExistence`
     result (`_ =`) and audited a possibly-transient frame.
   - The two model-pack tests tapped `settings-button` with no wait, and scrolled with `.exists`
     gates, then tapped a CTA before it was `.isHittable` — racing the render.

## Fix (focused, no broad rewrite)

- **CI lane split** (`.github/workflows/ci.yml`): `unit-test` (`-only-testing:DspeechTests`) and
  `ui-test` (`-only-testing:DspeechUITests`) now run on separate runners with their own result
  bundles, retry, and per-bundle flake report (threshold 0). UI tests are fully isolated from the
  real-audio unit tests — the contention trigger is gone. All `check-release-ready.sh`-required
  CI strings preserved.
- **Decorative-motion gate** (`Dspeech/App/ContentView.swift`): the Start glow now honors
  `accessibilityReduceMotion` (a genuine accessibility win) and a UI-test launch flag
  `-dspeech.uitest.reduce-animations` via `DecorativeMotion.isDisabledForUITests`. When either is
  set, the infinite animation is not started, so the app reaches idle for audits.
- **Audit test hardening** (`DspeechUITests/AccessibilityAuditUITests.swift`): the shared `launch`
  helper passes `-dspeech.uitest.reduce-animations`; the failure-state test now asserts the error
  banner exists with non-empty copy and that the surface settled (Start present, Stop absent)
  before auditing.
- **UI helpers** (`DspeechUITests/DspeechUITests.swift`): added `openSettings(in:)` (waits for the
  settings button to be hittable + the sheet to finish presenting), `waitUntilHittable(_:)`, and
  `scrollToHittable(_:in:)`. The two model-pack tests now open settings via the helper and gate the
  download CTA on `.isHittable` before tapping.

The accessibility audit remains meaningful: it still hard-gates `.contrast`, `.elementDetection`,
`.textClipped`, `.hitRegion` on the same settled screens. Only decorative motion is removed during
the audit (the audit measures static layout, not animation).

## Verification

Real commands run by Mr.Dao after this patch was applied to mac24:

- `swift format lint --strict --recursive Dspeech DspeechTests DspeechUITests` → exit 0.
- Targeted flake regression lane:
  - `xcodebuild ... -only-testing:DspeechUITests/AccessibilityAuditUITests/testMainFailureState_errorBannerNotObscured -only-testing:DspeechUITests/DspeechUITests/testCorruptModelPackStateShowsContinueWithoutPath -only-testing:DspeechUITests/DspeechUITests/testVoiceFilterModelPackDownloadCTAIsEnabledAndStartsAcquisition -test-iterations 3 -retry-tests-on-failure ... build test`
  - result: `** TEST SUCCEEDED **`, `XCODE_RC=0`, `FLAKE_RC=0`, `flaky: 0`.
- Full isolated UI lane:
  - `xcodebuild ... -only-testing:DspeechUITests -test-iterations 3 -retry-tests-on-failure ... build test`
  - result: 20 UI/a11y tests passed, `** TEST SUCCEEDED **`, `XCODE_RC=0`, `FLAKE_RC=0`, `flaky: 0`.
- Full isolated unit lane:
  - `xcodebuild ... -only-testing:DspeechTests -test-iterations 3 -retry-tests-on-failure ... build test`
  - result: `** TEST SUCCEEDED **`, `XCODE_RC=0`, `FLAKE_RC=0`, `flaky: 0`.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/release/check-release-ready.sh` → unsigned release-readiness checks passed; signing/ASC still unverified because `op` is unavailable/not signed in.

Not claimed yet in this note: GitHub hosted CI green after push. The branch must be pushed and the next Actions run must complete green before treating hosted CI as closed.

## Anti-regression lesson

- A UI test must never interact with a control before it is `.isHittable`, and must never audit or
  assert against a transient frame — gate on hittability and on a *settled* state, not on `.exists`.
- Infinite/`repeatForever` decorative animations break XCUITest idle assumptions; decorative motion
  must be suppressible under reduce-motion and under a UI-test flag.
- UI suites must not share a runner with CPU-heavy unit tests; isolate lanes so first-attempt
  stability does not depend on runner load.
- Gate added: split lanes + per-bundle flake report (threshold 0) keep retries as a *detector*. Any
  future first-attempt flake fails CI loudly instead of being silently absorbed.
