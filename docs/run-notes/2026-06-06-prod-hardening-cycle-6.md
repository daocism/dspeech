# 2026-06-06 Prod hardening Cycle 6 — hosted UI flake cleanup after Cycle 5

## Context

CI run `27053664269` on `9140baf` failed only because strict UI flake gate found retry-recovered tests:

- `DspeechUITests.testSettingsShowsNoOnDeviceRecognitionLocaleState`
  - first attempt timed out evaluating a UI query while the test used a raw settings tap plus `while !exists { swipeUp() }`.
- `DspeechUITests.testVoiceFilterModelPackDownloadCTAIsEnabledAndStartsAcquisition`
  - first attempt tapped `voicefilter-modelpack-cancel` after acquisition/install had already moved past that transient state.

Both tests passed on retry, so this cycle keeps `FLAKE_THRESHOLD=0` and removes the first-attempt races.

## Changes

- `testSettingsShowsNoOnDeviceRecognitionLocaleState`
  - uses hardened `openSettings(in:)` instead of raw `settings-button.tap()`;
  - uses `scrollToHittable(unavailable, in: app)` instead of existence-only swipe loop.
- `testVoiceFilterModelPackDownloadCTAIsEnabledAndStartsAcquisition`
  - stops tapping the transient cancel button after the transition assertion;
  - the behavior under test remains: CTA is hittable/enabled, tap runs, and UI transitions to acquiring/progress/installed.

## Verification

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift format lint --strict --recursive Dspeech DspeechTests DspeechUITests
# exit 0
```

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Dspeech.xcodeproj \
  -scheme Dspeech \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
  -only-testing:DspeechUITests/DspeechUITests/testSettingsShowsNoOnDeviceRecognitionLocaleState \
  -only-testing:DspeechUITests/DspeechUITests/testVoiceFilterModelPackDownloadCTAIsEnabledAndStartsAcquisition \
  -test-iterations 3 \
  -retry-tests-on-failure \
  -resultBundlePath /tmp/DspeechCycle6TargetUI.xcresult \
  CODE_SIGNING_ALLOWED=NO build test
scripts/ci/report-test-flakes.sh /tmp/DspeechCycle6TargetUI.xcresult
# ** TEST SUCCEEDED **
# flaky: 0
# XCODE_RC=0 FLAKE_RC=0
```

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Dspeech.xcodeproj \
  -scheme Dspeech \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
  -only-testing:DspeechUITests \
  -test-iterations 3 \
  -retry-tests-on-failure \
  -resultBundlePath /tmp/DspeechCycle6FullUI.xcresult \
  CODE_SIGNING_ALLOWED=NO build test
scripts/ci/report-test-flakes.sh /tmp/DspeechCycle6FullUI.xcresult
# ** TEST SUCCEEDED **
# flaky: 0
# XCODE_RC=0 FLAKE_RC=0
```

Read-only critical review: `APPROVED`.

## Anti-regression / lessons

- Do not poll `exists` in a swipe loop for deep Settings rows on hosted runners; use `scrollToHittable` so the query and viewport state settle together.
- Do not tap transient cleanup controls after the behavior assertion unless cleanup is the behavior under test; state can legitimately move to installed before the tap.
