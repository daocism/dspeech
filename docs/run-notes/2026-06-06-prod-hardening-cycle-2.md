# Prod hardening — Cycle 2: remove hosted unit metering flakes

Date: 2026-06-06
Branch: `fix/review-hardening-2026-06-03`
Base HEAD before work: `1c6ef567f69b2874d2b0f4d21e5d2938ded3c32f`

## Blocker addressed

After Cycle 1 split the CI into isolated unit and UI/a11y lanes, GitHub run `27050287547` showed
the UI/a11y lane moving independently, but the unit lane failed its strict flake report:

- `AudioSourceControllerTests.startMeteringPublishesLevels()` — attempts: Failed, Failed, Passed
- `AudioSourceControllerTests.startMeteringSurfacesFailureAndStopsMetering()` — attempts: Failed, Passed, Passed

`Build and test` still ended `** TEST SUCCEEDED **`; `scripts/ci/report-test-flakes.sh` correctly
failed because retry-recovered flakes exceeded threshold 0.

## Root cause

The tests used a deterministic fake meter, but their helper waited only 2 seconds for an
unstructured `Task { @MainActor ... }` in `AudioSourceController.startMetering()` to consume the
`AsyncStream`. On hosted macOS, the unit lane runs a large Swift/XCTest suite with parallel test
repetitions, and the newly-created MainActor task can be delayed long enough for the harness timeout
to expire. The product behavior was not changing; the test timeout was too tight for CI scheduler
contention.

## Fix

`DspeechTests/AudioSourceControllerTests.swift` now gives the metering wait helper 10 seconds of
headroom. This does not raise the flake threshold, skip tests, or add retries; the assertions remain
strict and still fail if the fake meter never publishes the expected level/error state. It removes
retry-dependence caused by a test-harness scheduling timeout.

## Verification

Real commands run by Mr.Dao on mac24 after this patch was applied:

- Targeted metering regression lane:
  - `xcodebuild ... -only-testing:DspeechTests/AudioSourceControllerTests -test-iterations 3 -retry-tests-on-failure ... build test`
  - result: `** TEST SUCCEEDED **`, `XCODE_RC=0`, `FLAKE_RC=0`, `flaky: 0`.
- Full isolated unit lane:
  - `xcodebuild ... -only-testing:DspeechTests -test-iterations 3 -retry-tests-on-failure ... build test`
  - result: `** TEST SUCCEEDED **`, `XCODE_RC=0`, `FLAKE_RC=0`, `flaky: 0`.
- `swift format lint --strict --recursive Dspeech DspeechTests DspeechUITests` → exit 0.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/release/check-release-ready.sh` → unsigned release-readiness checks passed; signing/ASC still unverified because `op` is unavailable/not signed in.

Not claimed yet in this note: GitHub hosted CI green after this second push. The next Actions run must complete green before treating hosted CI as closed.

## Anti-regression lesson

Any async unit test that waits on an unstructured MainActor task needs timeout headroom based on the
slowest hosted CI lane, not on a local Mac happy path. Retry remains a detector only; if a test needs
a retry, its harness timing contract is still wrong and must be fixed at source.
