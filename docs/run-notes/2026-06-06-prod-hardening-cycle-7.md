# 2026-06-06 Prod hardening Cycle 7 — hosted unit flake cleanup after Cycle 6

## Context

CI run `27054287767` on `4e93d67` failed only because strict unit flake gate found retry-recovered tests:

- `AudioSourceControllerTests/startMeteringPublishesLevels()`
- `LiveTranscriptionViewModelTests/startSwitchesToListening()`

The first attempts stalled on hosted Xcode 26.5 / iOS 26.5 around Swift Testing parallel cold-start. Both tests passed on retry and the final test state was correct:

- total: `430`
- passed: `429`
- skipped: `1`
- failed: `0`
- flaky: `2` with threshold `0`

## Changes

- Kept production code unchanged.
- Kept final assertions unchanged.
- Extended the existing asynchronous wait helpers from `10s` to `30s` in:
  - `DspeechTests/AudioSourceControllerTests.swift`
  - `DspeechTests/LiveTranscriptionViewModelTests.swift`
- Updated the AudioSourceController test comment to describe this as hosted-runner scheduler headroom, not a product timing invariant.

## Verification

RED evidence:

```bash
gh api repos/daocism/dspeech/actions/jobs/79855506601/logs > /tmp/dspeech-ci-27054287767-unit.log
# first attempt failed:
# - AudioSourceControllerTests/startMeteringPublishesLevels()
# - LiveTranscriptionViewModelTests/startSwitchesToListening()
# flake report: flaky **2** threshold 0
```

GREEN / regression checks:

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
  -only-testing:DspeechTests/AudioSourceControllerTests/startMeteringPublishesLevels \
  -only-testing:DspeechTests/LiveTranscriptionViewModelTests/startSwitchesToListening \
  -test-iterations 3 \
  -retry-tests-on-failure \
  -resultBundlePath /tmp/DspeechCycle7TargetUnit2.xcresult \
  CODE_SIGNING_ALLOWED=NO build test
scripts/ci/report-test-flakes.sh /tmp/DspeechCycle7TargetUnit2.xcresult
# ** TEST SUCCEEDED **
# flaky: 0
# XCODE_RC=0 FLAKE_RC=0
```

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Dspeech.xcodeproj \
  -scheme Dspeech \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
  -only-testing:DspeechTests \
  -test-iterations 3 \
  -retry-tests-on-failure \
  -resultBundlePath /tmp/DspeechCycle7FullUnit.xcresult \
  CODE_SIGNING_ALLOWED=NO build test
scripts/ci/report-test-flakes.sh /tmp/DspeechCycle7FullUnit.xcresult
# ** TEST SUCCEEDED **
# flaky: 0
# XCODE_RC=0 FLAKE_RC=0
```

```bash
python3 scripts/release/check-release-policy.py --source-only
git diff --check
# Release policy source checks passed.
# exit 0
```

```bash
DSPEECH_ALLOW_DIRTY_RELEASE=1 scripts/release/check-release-ready.sh
# Release policy source checks passed.
# Building fresh unsigned archive for release readiness check...
# Release policy source + archive checks passed.
# Signed/TestFlight prerequisites: UNVERIFIED (op unavailable).
# Unsigned release-readiness checks passed (fresh archive built and validated).
```

Read-only critical review: `APPROVED`; reviewer noted the old comment wording, then the comment was tightened before commit.

## Anti-regression / lessons

- Hosted-runner cold-start stalls are not product invariants; when the fake eventually delivers deterministic state and retry is the only failure, keep assertions strict and budget the wait above observed scheduler starvation.
- Use `FLAKE_THRESHOLD=0` as the learning loop: do not hide flakes by raising the threshold; either remove the race or document why the wait budget is test harness headroom.
