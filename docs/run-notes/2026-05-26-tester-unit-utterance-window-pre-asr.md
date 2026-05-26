# tester-unit verification — W2 utterance-aware pre-ASR pilot suppression

Run: `dspeech-builder-20260526T110023Z-29c9c067` · role `tester-unit`
Branch: `feat/local-pilot-voice-filter`
Date: 2026-05-26
Verdict: **PASS — does not block merge.**

## Commit(s) tested

| SHA | Subject |
| --- | --- |
| `d3d95ad` | docs(run-notes): record W2 utterance-window pre-ASR test evidence (TEST SUCCEEDED) |
| `aee9c8c` | feat(voice-filter): utterance-window pre-ASR pilot suppression (W2) |
| `2ce3570` | docs(ai): W2 utterance-aware pre-ASR discard acceptance contract |

Tested at branch tip `d3d95ad911a5fa462943b10d27765bd33e9e95d0`. mac24 working
copy confirmed at the same SHA before the test run.

## Scope check — limited to the W2 slice + evidence docs

`git diff --stat 3bf49b8..d3d95ad` (six files, +695/−11):

- `Dspeech/Core/ASR/UtteranceWindowRouter.swift` — **new** (67 lines), the window
  router; wraps the unchanged `SerialBufferRouter<[Buffer]>`.
- `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift` — swaps the gate's
  `SerialBufferRouter` for `UtteranceWindowRouter`, window = `sampleRate × 1.0s`.
- `Dspeech.xcodeproj/project.pbxproj` — appended file/group/build/source entries
  for the two new files (IDs `…0154`–`…0157`); no existing IDs renumbered.
- `DspeechTests/UtteranceWindowRouterTests.swift` — **new** (301 lines).
- `docs/run-notes/2026-05-26-utterance-window-pre-asr.md` — engineer evidence.
- `.ai/runs/…-29c9c067-researcher-codebase.md` — W2 acceptance contract.

`SerialBufferRouter.swift` and `SerialBufferRouterTests.swift` are untouched, so
the W1 FIFO guarantee is reused, not reimplemented. No production file outside the
ASR routing seam was touched.

## Command run (full DspeechTests suite on mac24)

```bash
ssh mac24 'cd /Users/andre/projects/dspeech-ios && git fetch origin && \
  git checkout feat/local-pilot-voice-filter && \
  git pull --ff-only origin feat/local-pilot-voice-filter && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Dspeech.xcodeproj -scheme Dspeech \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
    -only-testing:DspeechTests CODE_SIGNING_ALLOWED=NO test'
```

## Result — PASS

`xcodebuild … test` exited **0**. Every reported test case `passed`, zero
failures. The 8 W2 cases under `UtteranceWindowRouterTests`:

| Test | Status |
| --- | --- |
| `subThresholdWindowIsNeverDiscarded` | passed |
| `coherentPilotWindowIsDiscardedAsUnit` | passed |
| `transcribeWindowAppendsAllBuffersInOrder` | passed |
| `classifierErrorAppendsWindowAsUnit` | passed |
| `chunksAppliedInSubmitOrder` | passed |
| `finishFlushesPendingTailInOrder` | passed |
| `finishPreventsFutureAppends` | passed |
| `inFlightChunkDoesNotAppendAfterFinish` | passed |

W1 `SerialBufferRouterTests` (5 cases) remained green, confirming no regression in
the serial core the window router builds on.

## Fail-open behavior (mission check #4) — independently confirmed

| Required fail-open path | Evidence (test, all green) |
| --- | --- |
| classifier unavailable / error → transcribe | `UtteranceWindowRouterTests.classifierErrorAppendsWindowAsUnit`; engine `routeSamples` returns `.transcribe(.classifierUnavailable)` when no gate / self deallocated; pipeline `SpeechAudioBufferGateTests.thrownClassifierErrorFailsOpenToASR`, `…unavailableIdentifierFailsOpenToASR` |
| mixed / insufficient / non-pilot → transcribe | `transcribeWindowAppendsAllBuffersInOrder` (`.mixedOrLowConfidence`); `SpeechAudioBufferGateTests.mixedTranscribes`, `nonPilotTranscribes`, `insufficientSpeechFailsOpenToASR` |
| too-short / incomplete utterance → transcribe | `subThresholdWindowIsNeverDiscarded`, `finishFlushesPendingTailInOrder` (pending sub-window tail flushed to ASR on `finish()`, never classified) |
| no network path added | `grep -iE 'URLSession\|URLRequest\|http\|socket\|dataTask\|upload\|cloud'` over both W2 production files → no matches. `UtteranceWindowRouter.swift` imports only `Foundation`. No cloud/network code path introduced; ADR 0002 local-only invariant intact. |

## Residual risk

- **Low — window size is a fixed 1.0s constant** (`decisionWindowSeconds`),
  anchored to FluidAudio `minSpeechDuration` but not test-driven at the engine
  layer; the router-level contract is verified via injected `minimumChunkSamples`,
  so the engine's seconds→samples wiring (`sampleRate × 1.0`) is covered only by
  the build, not an assertion. Acceptable: it is a single arithmetic expression,
  not branching logic.
- **Low — engine integration is not exercised by a real `SFSpeech` request** in
  unit tests (by design — the seam is closure-injected). Real-audio behavior is
  out of unit-test scope and belongs to a device/integration pass.

Neither risk blocks merge. The slice is verified against the build/test evidence
above.
