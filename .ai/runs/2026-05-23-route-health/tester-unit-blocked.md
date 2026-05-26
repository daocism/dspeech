# tester-unit BLOCKED — production defect in engineer-ios `AudioSessionRouting.swift`

Run: `dspeech-builder-20260523T152250Z-53ab81d7`
Commit under test: `5235e0b` (pushed to `origin/feat/local-pilot-voice-filter`)

## Failure

Test build cannot compile. `xcodebuild build test` aborts before any `@Test` method executes.

```
Testing failed:
  Instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead
  Instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead
  Instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead
  Instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead
  Testing cancelled because the build failed.

** TEST FAILED **

The following build commands failed:
  SwiftCompile normal arm64 Compiling AudioSessionRouting.swift /Users/andre/projects/dspeech-ios/Dspeech/Core/Audio/AudioSessionRouting.swift (in target 'Dspeech' from project 'Dspeech')
(3 failures)
```

## Failing offender (production code, NOT mine)

`Dspeech/Core/Audio/AudioSessionRouting.swift`, in `FakeAudioSessionRouting`:

```swift
func requestRecordPermission() async -> Bool {
    lock.lock(); defer { lock.unlock() }   // ← lock/unlock invalid in async context
    return _permissionGranted
}
```

The same `lock.lock(); defer { lock.unlock() }` pattern in the synchronous methods (`currentRouteSnapshot`, `availableInputSnapshots`, `setPreferredInput`, `updateRoute`, `preferredInputCalls`) compiles fine — only the `async` method hits the diagnostic.

## Expected behavior

`xcodebuild ... build test` should compile `FakeAudioSessionRouting` cleanly and proceed to run `RouteHealthClassifierTests` + `RouteHealthMonitorTests` (~30 tests total). The compiler error is a real Swift 6 / iOS 26 SDK rule, not a flaky tool failure.

## Actual behavior

Compiler refuses the lock/unlock calls in the async function. Build aborts. No tests run.

## Failing test names

All RouteHealth tests are blocked because the test target's dependency (`FakeAudioSessionRouting` via `AudioSessionRouting.swift`) does not compile. The async permission method isn't directly invoked by any of my tests, but the file-level compile failure poisons the whole target.

Blocked test classes:
- `RouteHealthClassifierTests` (24 tests in `DspeechTests/RouteHealthClassifierTests.swift`)
- `RouteHealthMonitorTests` (24 tests in `DspeechTests/RouteHealthMonitorTests.swift`)

## Exact command used

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

Destination resolved: `iPhone 17 Pro (32AF0651-C9D5-4A80-BB1E-5FFD62B75DF0)` (iOS 26.4 simulator).

xcresult log path on mac24:
`/Users/andre/Library/Developer/Xcode/DerivedData/Dspeech-agmpzhijbukadidbkcyaauytxvwx/Logs/Test/Run-Dspeech-2026.05.23_17-34-28-+0200.xcresult`

## Suggested fix (for engineer-ios, NOT applied here per tester-unit role contract)

Two valid options, both production-side:

1. Drop the lock from `requestRecordPermission` — `_permissionGranted` is set only in `init` and never mutated, so the access doesn't need the lock at all. Make `_permissionGranted` `let`, then `return _permissionGranted` directly.
2. Convert `FakeAudioSessionRouting` to an `actor`, or wrap mutable state in `OSAllocatedUnfairLock<State>`. The structurally consistent fix because the `AudioSessionRouting` protocol is declared `Sendable` and `requestRecordPermission` is genuinely async.

## Secondary production defect (latent, not blocking today)

`Dspeech.xcodeproj/project.pbxproj:137` — test-target Release config `A00000000000000000000040 /* Release */` has `name = Debug` (should be `name = Release`). Two configs in the same `XCConfigurationList` claim the name "Debug". `xcodebuild ... build test` defaults to Debug action and resolves to the actually-Debug config, so today's failure is the lock issue, not this. Any `-configuration Release` build of the test target will misbehave. Fix in the same commit as the lock fix.

## Handoff

- I will NOT edit `Dspeech/Core/Audio/AudioSessionRouting.swift` or `project.pbxproj` (production files; outside my role).
- The strengthened tests are committed + pushed (`5235e0b`), ready to run as soon as engineer-ios's compile defect resolves.
- Re-running the verbatim xcodebuild command above after the fix should be sufficient — no test changes needed unless the public API of the routing types changes.
