# tester-unit — route-health behavioral test pass

Run: `dspeech-builder-20260523T152250Z-53ab81d7`
Role slug: `tester-unit`
Branch: `feat/local-pilot-voice-filter`
Status: **partial — tests authored & committed, xcodebuild BLOCKED on engineer-ios production defect (see `tester-unit-blocked.md`)**

## Commit
`5235e0b test(audio): cover route health transitions` (pushed to origin)

Bundled engineer-ios's 5 untracked Swift files + pbxproj wiring (unmodified, just `git add`) so the test target can build. My edits are only the two test files.

## Tests added/changed

### `DspeechTests/RouteHealthClassifierTests.swift` (extended)
- `outputOnlyPortsAreNotInputCapable` — extended to assert every non-output port is also `!isOutputOnly`
- `builtInSpeakerOnlyAvailableIsUnsuitable`
- `headphonesOnlyAvailableIsUnsuitable`
- `hdmiOnlyAvailableIsUnsuitable`
- `builtInSpeakerAsDirectInputIsUnsuitable`
- `headphonesAsDirectInputIsUnsuitable`
- `hdmiAsDirectInputIsUnsuitable`
- `bluetoothLEIsSuitableExternal_pinningCurrentBehavior`
- `airPlayIsSuitableExternal_pinningCurrentBehavior`
- `emptyRouteWithSuitableAvailableInputIsNoInput`
- `emptyRouteWithMixedAvailableInputsIsNoInput`
- `unknownRawValuePreservedThroughAssessment`
- `portTypeAliasesMapToHeadsetMic`
- `portTypeRawValueRoundTripForAllKnownCases`
- `primaryInputIsFirstInputEvenWithMultiple`

### `DspeechTests/RouteHealthMonitorTests.swift` (extended)
- `displayCopyAvoidsCertifiedLanguage` — extended forbidden-substring list and now also checks `shortLabel`
- `bannerCopyAvoidsCertifiedLanguage` — new, exercises `RouteChangeNotice.bannerText` for all four kinds
- `bannerTextIsEmptyForSilentNotice`
- `bannerTextIsNonEmptyForVisibleKinds`
- `blocksStartOnlyForNoInput` — parameterized across 5 health states
- `newDeviceAvailableWithoutImprovementIsSilent`
- `newDeviceAvailableDownshiftIsSilent`
- `oldDeviceUnavailableFromBuiltInIsSilent`
- `overrideEventIsSilentRecompute`
- `wakeFromSleepIsSilentRecompute`
- `routeConfigurationChangeIsSilentRecompute`
- `unknownRawEventIsSilentRecompute`
- `clearNoticeResetsBanner`
- `refreshFromRoutingPicksUpNewRoute`
- `noticeTimestampUsesInjectedClock` — deterministic clock injection
- `noSuitableRouteEmitsBlockingNotice`
- `bluetoothLEHealthBannerIsUserVisibleOnImprovement`
- `startAndStopAreIdempotent`

Forbidden-substring guard:
`["certif", "guarantee", "radio link", "tower link", "faa", "easa"]`

## Behavior matrix covered

| Scenario | Expected health | Notice |
|---|---|---|
| empty route, no available inputs | `.noInput` (blocks start) | — |
| empty route, only output-only available (A2DP/speaker/headphones/HDMI) | `.unsuitableOutputOnly` | — |
| empty route, suitable available but no route input | `.noInput` | — |
| route input = builtInMic | `.cautionBuiltIn` (start allowed) | — |
| route input = headset / line-in / USB / HFP / car / LE / AirPlay | `.suitableExternal` (LE+AirPlay pinned) | — |
| route input = output-only (A2DP/speaker/headphones/HDMI) | `.unsuitableOutputOnly` | — |
| route input = unknown raw type | `.unknownExternal`, raw preserved | — |
| built-in → external + `.newDeviceAvailable` | climbs | `.improved` (user-visible) |
| no climb + `.newDeviceAvailable` | unchanged | `.silent` |
| downshift + `.newDeviceAvailable` | drops | `.silent` |
| external → built-in + `.oldDeviceUnavailable` | drops | `.lost` (user-visible) |
| built-in stays + `.oldDeviceUnavailable` | unchanged | `.silent` |
| `.noSuitableRouteForCategory` | `.noInput` | `.noSuitableRoute` (user-visible) |
| `.categoryChange` / `.override` / `.wakeFromSleep` / `.routeConfigurationChange` / `.unknown(N)` | recomputed | `.silent` |
| copy guard: displayLabel + shortLabel + bannerText | no certif/guarantee/radio link/tower link/FAA/EASA | — |
| clock injection | deterministic timestamp | — |
| start/stop idempotency | no duplicate task | — |

## Pinning rationale — bluetoothLE & airPlay

Engineer-ios's `RouteHealthClassifier` maps both `.bluetoothLE` and `.airPlay` to `.suitableExternal`. I pinned this with named tests rather than silently asserting.

- **BluetoothLE risk:** iOS 17/18/26 has inconsistent BLE-audio voice-capture MTU/codec behavior. Conservative default would be `.unknownExternal` until real-hardware validation.
- **AirPlay risk:** AirPlay capture is rare and high-latency. Conservative default would be `.unknownExternal`.

Pinning tests catch a silent flip either way. If product decides conservative later, update both expectations and the rationale comment.

## xcodebuild destination and result

Command (per brief):
```
ssh mac24 'cd /Users/andre/projects/dspeech-ios && \
  git fetch origin feat/local-pilot-voice-filter && \
  git checkout feat/local-pilot-voice-filter && \
  git pull --ff-only && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project Dspeech.xcodeproj -scheme Dspeech \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
    CODE_SIGNING_ALLOWED=NO build test'
```

Destination available: `iPhone 17 Pro (32AF0651-C9D5-4A80-BB1E-5FFD62B75DF0)` on mac24.

**Result: `** TEST FAILED **`** — build did not reach the test runner.

Root cause: `Dspeech/Core/Audio/AudioSessionRouting.swift` uses `NSLock.lock()` / `unlock()` inside an `async` method (`requestRecordPermission()`). Swift 6 strict concurrency / iOS 26 SDK marks these as `unavailable from asynchronous contexts`. See `tester-unit-blocked.md`.

## Latent production defect (pbxproj)

`Dspeech.xcodeproj/project.pbxproj:137` — test target's Release config `A00000000000000000000040 /* Release */` now has `name = Debug`. Two `XCConfigurationList` entries both named "Debug". Default `xcodebuild build test` did not surface this (Debug action picked the actual Debug config). Any Release build of the test target will resolve ambiguously. Not blocking today's run; fix in same engineer-ios revision as the lock issue.

## Remaining risk

1. **Tests not yet executed.** Cannot confirm green until the lock defect is resolved and the build reaches the runner. Tests are deterministic (injected `now: () -> Date`, `FakeAudioSessionRouting` only collaborator, no real clock/network/randomness). Assertions match engineer-ios behavior as read on `5235e0b`. Expected: all green once build green.
2. **No JSON fixtures.** Brief allowed optional `DspeechTests/Fixtures/AudioRoute/`. Kept literals — every scenario is one line of `PortSnapshot(...)`; adding pbxproj fixture-membership churn would be heavier than the assertions themselves.
3. **No real-hardware BLE/AirPlay data.** Pinning tests are deliberately fragile to a product-decision change.
4. **`@unchecked Sendable` + `NSLock` in `FakeAudioSessionRouting`.** Once engineer-ios switches locking (probably to actor / `OSAllocatedUnfairLock`), fixtures may need rebuild but assertions stay valid.

## Next pass
- Once engineer-ios fixes the `NSLock` async issue, re-run the verbatim xcodebuild command. No test changes needed unless public API of `RouteHealthClassifier` / `RouteHealthMonitor` / `AudioSessionRouting` changes.
- Revert pbxproj line 137 `name = Debug` back to `name = Release` in the same fix commit.
