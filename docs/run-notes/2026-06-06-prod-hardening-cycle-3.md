# 2026-06-06 Prod hardening Cycle 3 — deterministic CI flakes + a11y text clipping

## Context

Cycle 2 (`b30974b`) was locally green but hosted CI run `27050624313` failed because the strict flake gate found retry-recovered tests:

- Unit job `79845302336`: `18 flaky test(s) exceeded threshold 0`.
  - Mostly `LiveTranscriptionViewModelTests`, plus `CaptureCoordinatorTests/startAllowedForCautionBuiltIn()`.
- UI job `79845302349`: `2 flaky test(s) exceeded threshold 0`.
  - `AccessibilityAuditUITests/testMainFailureState_errorBannerNotObscured()`.
  - `DspeechUITests/testCorruptVoiceFilterStorageShowsRecoveryBanner()`.

The code under test passed after retry, so the production risk was not a deterministic functional regression; the release blocker was nondeterministic first-attempt behavior under cold hosted runner scheduling/TCC/UI-settling pressure. The policy stays strict: retry is a detector, not a mask (`FLAKE_THRESHOLD=0`).

## Changes

- Serialized the two MainActor-heavy Swift Testing suites that drive unstructured live transcription observation/translation tasks:
  - `LiveTranscriptionViewModelTests`
  - `CaptureCoordinatorTests`
- Increased their polling helpers from 5s to 10s to match hosted-runner scheduler headroom while preserving the same final assertions.
- Hardened failure-state a11y UI test:
  - handles permission alerts from both app and SpringBoard;
  - avoids broad allow-label matching that could tap a deny action;
  - waits for a settled, non-empty `error-banner` and idle Start state before the audit.
- Hardened corrupt voice-filter storage UI test:
  - uses `openSettings(in:)` (hittable settings button + presented sheet) before scrolling;
  - requires the recovery banner to become hittable/visible, not just query-existing.
- Fixed a real German settings a11y regression found by full UI verification:
  - the raw `FluidInference/speaker-diarization-coreml` repository slug clipped in the localized Settings privacy caption;
  - visible UI now uses a short `Core ML` package label and a shorter German string while the detailed source remains in installer/ADR docs.

## Verification

All commands below were run on `mac24:/Users/andre/projects/dspeech-ios` with Xcode 26.4 / iPhone 17 Pro iOS 26.4 simulator.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   swift format lint --strict --recursive Dspeech DspeechTests DspeechUITests
# exit 0
```

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild   -project Dspeech.xcodeproj   -scheme Dspeech   -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4"   -only-testing:DspeechTests/LiveTranscriptionViewModelTests   -only-testing:DspeechTests/CaptureCoordinatorTests   -test-iterations 3   -retry-tests-on-failure   -resultBundlePath /tmp/DspeechCycle3Unit.xcresult   CODE_SIGNING_ALLOWED=NO build test
scripts/ci/report-test-flakes.sh /tmp/DspeechCycle3Unit.xcresult
# ** TEST SUCCEEDED **
# flaky: 0
# XCODE_RC=0 FLAKE_RC=0
```

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild   -project Dspeech.xcodeproj   -scheme Dspeech   -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4"   -only-testing:DspeechUITests/AccessibilityAuditUITests/testMainFailureState_errorBannerNotObscured   -only-testing:DspeechUITests/DspeechUITests/testCorruptVoiceFilterStorageShowsRecoveryBanner   -test-iterations 3   -retry-tests-on-failure   -resultBundlePath /tmp/DspeechCycle3UI.xcresult   CODE_SIGNING_ALLOWED=NO build test
scripts/ci/report-test-flakes.sh /tmp/DspeechCycle3UI.xcresult
# ** TEST SUCCEEDED **
# flaky: 0
# XCODE_RC=0 FLAKE_RC=0
```

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild   -project Dspeech.xcodeproj   -scheme Dspeech   -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4"   -only-testing:DspeechUITests/AccessibilityAuditUITests/testMainFailureState_errorBannerNotObscured   -only-testing:DspeechUITests/AccessibilityAuditUITests/testSettings_de_default   -test-iterations 3   -retry-tests-on-failure   -resultBundlePath /tmp/DspeechCycle3TargetUI3.xcresult   CODE_SIGNING_ALLOWED=NO build test
scripts/ci/report-test-flakes.sh /tmp/DspeechCycle3TargetUI3.xcresult
# ** TEST SUCCEEDED **
# flaky: 0
# XCODE_RC=0 FLAKE_RC=0
```

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild   -project Dspeech.xcodeproj   -scheme Dspeech   -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4"   -only-testing:DspeechTests   -test-iterations 3   -retry-tests-on-failure   -resultBundlePath /tmp/DspeechCycle3FullUnit2.xcresult   CODE_SIGNING_ALLOWED=NO build test
scripts/ci/report-test-flakes.sh /tmp/DspeechCycle3FullUnit2.xcresult
# ** TEST SUCCEEDED **
# flaky: 0
# XCODE_RC=0 FLAKE_RC=0
```

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild   -project Dspeech.xcodeproj   -scheme Dspeech   -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4"   -only-testing:DspeechUITests   -test-iterations 3   -retry-tests-on-failure   -resultBundlePath /tmp/DspeechCycle3FullUI3.xcresult   CODE_SIGNING_ALLOWED=NO build test
scripts/ci/report-test-flakes.sh /tmp/DspeechCycle3FullUI3.xcresult
# ** TEST SUCCEEDED **
# flaky: 0
# XCODE_RC=0 FLAKE_RC=0
```

```bash
python3 -m json.tool Dspeech/Localizable.xcstrings >/dev/null
# exit 0
```

```bash
scripts/release/check-release-ready.sh
# Building fresh unsigned archive for release readiness check...
# Warnings:
#  - signing/ASC secret validation skipped — op CLI unavailable or not signed in
# Signed/TestFlight prerequisites: UNVERIFIED (op unavailable).
# Unsigned release-readiness checks passed (fresh archive built and validated).
```

## Review

Read-only critical code review: `APPROVED`.

- The review confirmed the patch does not raise flake thresholds, skip tests, or weaken final assertions.
- Follow-up review risks were addressed before final verification:
  - exact/non-deny permission button matching;
  - shorter non-duplicative visible model label.

## Anti-regression / lessons

- Do not treat a green `xcodebuild` with retry as enough; always run `scripts/ci/report-test-flakes.sh` and require `flaky: 0`.
- For Swift Testing suites with MainActor view models plus unstructured tasks, serialize before increasing retry reliance.
- UI tests that interact with Settings must wait for hittable controls and presented sheets, not just `.exists`.
- A11y audits can reveal real product copy/layout bugs while debugging flakiness; fix the UI copy/layout rather than suppressing the audit.
