# tester-unit verification — pre-ASR serial buffer-routing hardening

- **Run id:** `dspeech-supervisor-20260525T203100Z-a08f1596`
- **Role:** tester-unit (deterministic Xcode verification)
- **Date:** 2026-05-25
- **Result:** ✅ PASS — `** TEST SUCCEEDED **`, 193 tests passed, 0 failed.

## SHA tested

| Field | Value |
|---|---|
| Branch | `fix/pre-asr-serial-buffer-routing` |
| Commit | `f39d8f6901e0ac30942af21b887e2134986c598c` |
| Subject | `fix(asr): serialize pre-ASR buffer routing to preserve capture order` |
| Base | `feat/local-pilot-voice-filter` (`2165900` on origin) |

## What the slice changes

- `Dspeech/Core/ASR/LiveTranscriptionEngine.swift` — adds `AudioBufferRouting` enum and a `@MainActor SerialAudioRoutingQueue<Element>`: a single sequential consumer over an `AsyncStream` so buffer N+1 is not routed until buffer N's transcribe/discard decision and any append complete.
- `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift` — capture tap now `submit`s into the serial queue (no per-buffer `Task`, whose start order is unguaranteed); extracts `routeBuffer(_:)` with fail-open semantics (no gate → `.transcribe`; unsupported sample format → `.transcribe`; thrown classifier error → `.transcribe`); `cleanup()` calls `routingQueue.finish()` before niling the request. Adds `@unchecked Sendable` `SendableAudioBuffer` for the single-hand-off crossing.
- `DspeechTests/VoiceFilterTests.swift` — +153 lines, two new suites (verified below). Tests are deterministic (spin/`Task.yield`, no real clock/network/randomness) and were **not weakened**.

## Commands

mac24 dirty-state check:

```bash
ssh mac24 'cd /Users/andre/projects/dspeech-ios && git status --porcelain'
# -> 4 untracked entries (.agent-logs/ .agent-prompts/ .agent-state/ docs/AUTOPILOT-JOURNAL.md)
```

Because the main checkout was non-clean, a **throwaway detached worktree** was created
(per the constraint) rather than touching `/Users/andre/projects/dspeech-ios`:

```bash
ssh mac24 'cd /Users/andre/projects/dspeech-ios && \
  git fetch origin fix/pre-asr-serial-buffer-routing && \
  git worktree add --detach /Users/andre/projects/_dspeech-supervisor-a08f1596-wt \
    f39d8f6901e0ac30942af21b887e2134986c598c'
```

Build + test (the existing verified pattern, full `DspeechTests` target):

```bash
ssh mac24 'cd /Users/andre/projects/_dspeech-supervisor-a08f1596-wt && \
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && \
  xcodebuild -project Dspeech.xcodeproj -scheme Dspeech \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
    -only-testing:DspeechTests CODE_SIGNING_ALLOWED=NO build test'
```

## Evidence

```
** TEST SUCCEEDED **
Test session results, code coverage, and logs:
  …/DerivedData/Dspeech-…/Logs/Test/Run-Dspeech-2026.05.25_22-48-26-+0200.xcresult
```

- Test cases reporting `passed on`: **193**
- Test cases reporting `failed on`: **0**
- The only log lines matching `failed|error:` are passing test *names*
  (`roundTripFailed`, `failedStateProducesUnavailable`, `failedStatusExposesErrorMessage`) — no actual failures.

New suites for this slice (all green):

```
Test suite 'SerialAudioRoutingQueueTests' started …
  SerialAudioRoutingQueueTests/preservesCaptureOrderWhenEarlierElementRoutesSlower()  passed (0.132s)
  SerialAudioRoutingQueueTests/discardedElementsDoNotAppend()                          passed (0.132s)
  SerialAudioRoutingQueueTests/failOpenRoutingStillAppendsInOrder()                    passed (0.132s)
  SerialAudioRoutingQueueTests/submitAfterFinishIsIgnored()                            passed
Test suite 'AppleSpeechRoutingTests' started …
  AppleSpeechRoutingTests/noGateRoutesTranscribe()                  passed (0.044s)
  AppleSpeechRoutingTests/unsupportedSampleFormatRoutesTranscribe() passed (0.044s)
  AppleSpeechRoutingTests/confidentPilotRoutesDiscard()             passed (0.048s)
  AppleSpeechRoutingTests/thrownClassifierErrorRoutesTranscribe()   passed (0.048s)
  AppleSpeechRoutingTests/nonPilotRoutesTranscribe()                passed (0.048s)
```

These pin the two core guarantees of the slice: (1) capture order is preserved across
variable routing latency and discards, and the queue stops accepting after `finish()`;
(2) the engine fails open to `.transcribe` for no-gate, unsupported-format, and thrown-classifier
paths, and routes `.discard` only for a confident pilot match.

## Failure snippets

None — clean pass.

## mac24 dirty-state handling

- `/Users/andre/projects/dspeech-ios` was **not** modified. Its 4 untracked entries are preserved
  (only a non-mutating `git fetch` + `git worktree add` were run from it). Post-run check:
  branch `feat/local-pilot-voice-filter`, `git status --porcelain` → 4 entries (unchanged).
- All build/test ran in the detached throwaway worktree
  `/Users/andre/projects/_dspeech-supervisor-a08f1596-wt` at the exact SHA.

## Cleanup

- Throwaway worktree **removed** after verification:
  `git worktree remove --force /Users/andre/projects/_dspeech-supervisor-a08f1596-wt` + `git worktree prune`.
  Confirmed gone (`ls` of the scratch glob → no matches). DerivedData for the throwaway build
  left in place (Xcode-managed cache, outside the repo — not repo litter).

## Verdict

The tested SHA `f39d8f6` builds and passes the full `DspeechTests` target (193 tests, 0 failures)
on iPhone 17 Pro / iOS 26.4. Verification approved.
