# Tester verification — speaker-identifier factory/gate slice (2026-05-25)

Run: `dspeech-builder-20260525T070045Z-aac9d282`, worker `tester-unit`.
Branch: `feat/local-pilot-voice-filter`. Verified at pushed tip **`49acd3a`**
(engineer code SHA `fd10aa0` + the concurrent `0fda374` research / `24dfbdf`
pre-ASR-gate commits all reachable from this tip). Independent of, and
complementary to, `docs/run-notes/2026-05-25-speaker-identifier-slice.md`.

## Branch state confirmed

- Worktree `git status --short --branch` → detached `HEAD` (AI-office throwaway
  worktree); the run-supplied base is `feat/local-pilot-voice-filter`.
- `origin/feat/local-pilot-voice-filter` = `49acd3a`. The engineer's work is fully
  pushed (no unpushed commits behind the tip). Verification ran against the pushed
  tip, not a local-only state.

## Commands (exact)

Focused suite, on mac24 (macOS 26.4.1, build 25E253) over SSH, against the freshly
fetched pushed tip:

```bash
# mac24:/Users/andre/projects/dspeech-ios @ 49acd3a
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project Dspeech.xcodeproj -scheme Dspeech \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
  -only-testing:DspeechTests CODE_SIGNING_ALLOWED=NO build test
```

Determinism re-run (twice) over the three slice suites:

```bash
-only-testing:DspeechTests/SpeechAudioBufferGateTests \
-only-testing:DspeechTests/LocalSpeakerIdentifierFactoryTests \
-only-testing:DspeechTests/VoiceFilterPipelineTests
```

- **Simulator destination:** `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4`
  (`32AF0651-…`), runtime `iOS 26.4 (23E244)`. Destination from the CLAUDE.md build
  recipe was available.

## Pass/fail summary

- Full `DspeechTests`: **`** TEST SUCCEEDED **`**, 0 failures, 0 skips.
- Slice suites re-run twice: **TEST SUCCEEDED** both times, identical pass counts
  (88 logged `passed` lines/run across parallel clones) → deterministic, no flake.
- Authored `@Test` functions covering the slice (source count):
  `VoiceFilterPipelineTests` 14 · `LocalSpeakerIdentifierFactoryTests` 14 ·
  `SpeechAudioBufferGateTests` 16 = **44** slice tests, all green
  (73 `@Test` total in `VoiceFilterTests.swift`).

## Fail-open (product safety) contract — independently confirmed

Every "do we drop possible ATC audio?" branch resolves to **transcribe** unless a
real classifier proves a confident pilot. Verified by reading the code paths AND
the green tests that pin each one:

| Condition | Path | Result | Pinned by |
|---|---|---|---|
| Absent pack | `classify` → `requireInstalledModelPack` throws → gate catch | transcribe (`classifierUnavailable`) | `absentPackFailsOpenToASR` |
| Disabled pack | same | transcribe | `disabledPackFailsOpenToASR` |
| Acquiring / failed pack | factory → `Unavailable` → throws | transcribe | factory `*ProducesUnavailable` |
| Filter disabled | `classify` early-returns `.nonPilot` | transcribe (`filterDisabled`) | `disabledFilterTranscribes` |
| No pilot profile | `classify` early-returns `.nonPilot` | transcribe (`noPilotProfile`) | `noProfileTranscribes` |
| Identifier unavailable (no backend — today's shipping build) | factory → `Unavailable` → throws | transcribe | `unavailableIdentifierFailsOpenToASR`, `installedWithoutBackendKeepsPipelineNotReady` |
| Classifier throws (capture/load failure) | gate `catch` | transcribe | `thrownClassifierErrorFailsOpenToASR`, `installedWithThrowingBackendFailsOpenToUnavailable` |
| Backend reports `.unavailable` | factory rejects | `Unavailable` → transcribe | `installedWithUnavailableBackendStaysUnavailable` |
| Embedding-dimension mismatch | factory rejects | `Unavailable` → transcribe | `installedWithDimensionMismatchStaysUnavailable` |
| Mixed / low-confidence speech | `routeBeforeTranscription` | transcribe (`mixedOrLowConfidence`) | `mixedTranscribes`, `factoryBackedPipelineKeepsMixedSpeechTranscribed` |
| Insufficient speech (silence/clip) | `routeBeforeTranscription` (was `.discard`, now fail-open) | transcribe (`insufficientSpeech`) | `insufficientSpeechFailsOpenToASR`, `routeBeforeTranscriptionFailsOpenForInsufficientSpeech` |
| **Confident pilot, installed pack + available matching backend** | factory builds real identifier; pipeline `.ready` | **discard (`pilotVoice`)** | `confidentPilotIsDiscardedBeforeASR`, `factoryBackedPipelineDiscardsConfidentPilotBeforeASR` |

The only discard path requires an installed pack **and** an available,
dimension-matching backend — exercised through a fake `StubBackendBuilder`
(no network, no real model), the correct test-only proof of a classifier decision.
`monoFloatSamples` extraction (mono passthrough, stereo averaging, nil on
non-float / empty buffer) is covered by 4 tests.

## No-network / privacy confirmation

- `grep -rniE "URLSession|http(s)?://|dataTask|download\(|ModelRegistry|huggingface"`
  over `Dspeech/` returns **no** runtime network path. The only URL-shaped strings
  are `mirror.invalid` test fixtures and doc citations.
- The default `ContentView` builds the pipeline via
  `LocalSpeakerIdentifierFactory.make(state:)` with `backendBuilder: nil` → always
  `UnavailableLocalSpeakerIdentifier` in the shipping build → no audio ever dropped
  pre-ASR today. No silent model download; construction is gated on persisted
  `ModelPackState`. ADR 0002 / ADR 0008 intact.
- No "certified"/flight-safety language: `RouteHealthMonitorTests`
  `bannerCopyAvoidsCertifiedLanguage` / `displayCopyAvoidsCertifiedLanguage` remain
  green.

## Environment handling (mac24)

The canonical `dspeech-ios` checkout was **dirty** at session start (HEAD `e024f20`,
a pre-gate commit, with an uncommitted divergent rewrite of
`AppleSpeechLiveTranscriptionEngine.swift` that *removes* the buffer-gate seam, plus
`DspeechUITests.swift`). To get a clean, deterministic run at the pushed tip I
`git stash`-preserved those two files, fast-forwarded to `49acd3a`, ran the suites,
then **restored mac24 exactly as found**: `reset --hard e024f20` + `stash pop`
(verified HEAD `e024f20` with both files re-modified, stash dropped clean). The
untracked `.agent-*` dirs and `docs/AUTOPILOT-JOURNAL.md` were never touched. No
litter, no host drift.

> Residual note: that stale uncommitted rewrite on mac24 deletes the very feature
> under review. It is leftover WIP on an old commit, not part of this branch, but a
> future build that `xcodebuild`s the dirty checkout directly (instead of the pushed
> tip) would not exercise the gate. Recommend the next mac24-side cycle either commit
> or discard it so the working checkout matches `origin`.

## Residual risks

1. **Integration seam untested at unit level.** `AppleSpeechLiveTranscriptionEngine`
   `.appendThroughGate` (the actual `gate → request.append` / `.discard → skip`
   wiring, and its `catch → append` fail-open) has no direct test — it needs a live
   `SFSpeechAudioBufferRecognitionRequest`/`AVAudioEngine`. The gate's routing logic
   and `monoFloatSamples` are covered separately; the seam itself is thin and
   fail-open by construction (non-float/empty/throw → append original). Acceptable
   for this slice; belongs to a future device/integration test.
2. **No real backend exists yet.** The discard path is proven only via fakes; the
   real `FluidAudioSpeakerIdentifier` is the next slice. Until then the shipping app
   is inert (everything transcribes) — which is the safe failure direction.
3. **PBT not added.** Per role guidance the `SpeakerMatcher` cosine/threshold logic
   (>3 branches) is a candidate for `tester-pbt`; example-based coverage is adequate
   for now (12 `SpeakerMatcherTests`).

## PR #2 verdict

**Safe for supervisor inspection.** The slice is fail-open in every
absent/disabled/failed/error/insufficient/mixed branch, drops audio only on a
proven confident-pilot classifier decision behind an installed pack + available
backend, adds no network path, makes no flight-safety/certified claim, and ships
inert by default. All 44 slice tests (and the full `DspeechTests` suite) pass
deterministically at the pushed tip `49acd3a` on iPhone 17 Pro / iOS 26.4.
