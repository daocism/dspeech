# 2026-06-06 Prod hardening Cycle 5 — FluidAudio registry scoping and resolved install source

## Context

After Cycle 4, release policy was green and CI run `27052814061` passed, including the new release-policy source gate. Remaining production-readiness risk was the FluidAudio download boundary itself:

- `ModelRegistry.baseURL` is a global FluidAudio setting.
- Dspeech applied mirror overrides by mutating that global before download.
- Without scoped serialization, concurrent/retried downloads could mix mirror/default URL resolution or leave the global polluted.
- Installed model-pack metadata recorded only the bare repo path, not the effective resolved source.

## Changes

- Added `SpeakerModelPackInstaller.RegistryBaseURLGate`:
  - `NSLock` + FIFO continuations;
  - serializes all Dspeech-owned scoped access to FluidAudio's global `ModelRegistry.baseURL` across the full async download.
- Added `withConfiguredRegistryBaseURL(...)`:
  - applies configured mirror override only inside the protected operation;
  - restores the previous base URL on success/throw/cancellation-through-throw;
  - leaves FluidAudio's own default/env resolution untouched when no override is configured.
- Updated `downloadModelPack(...)` to run `DownloadUtils.downloadRepo` inside the scoped helper.
- Updated install metadata:
  - `InstalledModelPack.source` now records the resolved effective source (`baseURL/source`) used by the install.
- Updated tests:
  - `SpeakerModelPackSourceTests` now verifies resolved mirror source, restore after success, restore after throw, and concurrent serialization.
  - `ReplayKitNetworkDenyTests.modelSourceOverrideFlowsToFluidAudioDownloadBaseURL` now uses the scoped helper instead of direct global mutation.
- Updated `docs/eval/local-speaker-model-pack-validation.md` to describe the scoped helper.

## Verification

RED first:

```bash
# After adding tests before implementation:
xcodebuild ... -only-testing:DspeechTests/VoiceFilterTests ... build test
# failed as expected:
# - extra argument 'infoDictionary' in resolvedRegistrySource
# - no member withConfiguredRegistryBaseURL
# RED_RC=65
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
  -only-testing:DspeechTests/VoiceFilterTests \
  -only-testing:DspeechTests/ReplayKitNetworkDenyTests \
  -resultBundlePath /tmp/DspeechCycle5Fix2.xcresult \
  CODE_SIGNING_ALLOWED=NO build test
# ** TEST SUCCEEDED **
# FIX2_RC=0
```

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Dspeech.xcodeproj \
  -scheme Dspeech \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
  -only-testing:DspeechTests \
  -test-iterations 3 \
  -retry-tests-on-failure \
  -resultBundlePath /tmp/DspeechCycle5FullUnit2.xcresult \
  CODE_SIGNING_ALLOWED=NO build test
scripts/ci/report-test-flakes.sh /tmp/DspeechCycle5FullUnit2.xcresult
# ** TEST SUCCEEDED **
# flaky: 0
# XCODE_RC=0 FLAKE_RC=0
```

```bash
python3 scripts/release/check-release-policy.py --source-only
bash -n scripts/release/build-unsigned-archive.sh scripts/release/check-release-ready.sh
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

Read-only critical review after concurrency fix: `APPROVED`.

## Anti-regression / lessons

- A global SDK setting must not be scoped across `await` without a non-reentrant lock; actors are not enough if their method awaits and can re-enter.
- Tests that mutate SDK globals must use the same scoped helper; direct global mutation is now treated as a test smell.
- Source metadata should record the effective resolved source, not just the nominal repo name, so mirror/download provenance is auditable.
