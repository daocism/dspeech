# Reviewer — utterance-aware pre-ASR pilot suppression (W1 + W2)

Run: `dspeech-builder-20260526T110023Z-29c9c067` · role `reviewer` · host `ubuntu-vm`
Branch: `feat/local-pilot-voice-filter` · origin tip `90dc4d8`
Reviewed:
- W1 serial routing: `a6b25ad` (test) → `541353d` (feat) → `3bf49b8` (docs)
- W2 utterance window: `2ce3570` (contract) → `aee9c8c` (feat) → `d3d95ad`/`90dc4d8` (test evidence)

> Note: origin advanced past the W1 tip during this review. The mission names the
> "utterance-aware" slice — that is **W2 (`aee9c8c`)**, now landed. This artifact
> reviews W2 as the substantive deliverable and W1 as its serial core.

## Verdict

**APPROVE_WITH_NOTES**

The discard decision genuinely moved from raw-tap-buffer to a coherent 1.0 s
decision window. Every uncertainty path fails open, no buffer can append after the
request ends, no network/cloud path is added, and the docs make no safety claim.
Notes below are non-blocking; the one substantive item (fixed-window vs co-located
dispatcher speech) is already disclosed as a residual risk and the mitigating VAD
slice is explicitly out of this cycle's scope.

## Findings against review focus

### 1. Raw-buffer → utterance/window discard — YES, real
`UtteranceWindowRouter` (`UtteranceWindowRouter.swift`) accumulates tap buffers
until `pendingSampleCount >= minimumChunkSamples` (engine sets this to
`recordingFormat.sampleRate × 1.0 s`), then submits the **whole concatenated
window for one classification** via the inner `SerialBufferRouter<[Buffer]>`,
whose append closure appends every buffer in the chunk as a unit (`init`,
`cutChunk`). A single mislabeled tap buffer can no longer punch a hole in an
utterance. This is the W1→W2 step the mission asked for, and it is implemented at
the window layer, not faked.

### 2. Can uncertain audio be silently dropped before ASR? — NO, on every path
- Sub-threshold window: never classified, held in `pending`; flushed on
  `finish()` (`UtteranceWindowRouter.submit` / `finish`). An isolated
  pilot-leaning fragment cannot trigger discard.
- Classifier throws → inner `drain` catches → `.transcribe(.classifierUnavailable)`
  → append whole window (`SerialBufferRouter.swift:50-53`). Also fails open one
  layer down in `VoiceFilterSpeechAudioBufferGate.route`
  (`LiveTranscriptionEngine.swift:50-54`).
- Non-float / empty buffer → `samples: []`; contributes 0 to the window count and
  rides the window's decision (or the tail flush). Empty-only audio → quality 0
  (`FluidAudioSpeakerIdentifier.swift:36`) → `.insufficientSpeech` → transcribe.
- `.discard` is reachable only from `speaker == .pilot` with filter enabled and a
  profile enrolled (`VoiceFilterPipeline.routeBeforeTranscription`); `.mixed` and
  `.insufficientSpeech` both fail open.

**NOTE A (MEDIUM, product safety — already disclosed):** the window boundary is a
fixed 1.0 s sample count, **not VAD/silence-segmented**. A window that straddles a
pilot→dispatcher transition is embedded as one vector; if it scores
`≥ pilotMatchThreshold` (0.72) against the pilot profile it is discarded as a unit,
dropping up to ~1 s of co-located dispatcher speech. The matcher's `.mixed` band
(`mixedSpeakerLowerBound` 0.62 ≤ score < 0.72, `SpeakerMatcher.match`) only buffers
the confidence margin, not the straddle case. Mitigations in place: the 0.72
threshold is high, real ATC transmissions are PTT-gated with dead air between
speakers (straddle is rare), and the run note discloses this as a residual risk
with VAD segmentation deferred. **No change requested in this cycle** — VAD
boundary detection is explicitly out of scope; flag carried to the VAD slice.

### 3. FIFO and `finish()` semantics — correct; the W1 mid-flight race is now pinned
- Cross-window FIFO holds: chunks drain through the serial inner router one at a
  time, `await`-ing each decision before the next (`chunksAppliedInSubmitOrder`).
- In my W1-only read I flagged that the inner `guard !finished else { break }`
  after the `await` (the stop-during-classification race) was **untested**. W2
  closes exactly that gap: `inFlightChunkDoesNotAppendAfterFinish` submits a
  complete window, lets classification begin, calls `finish()`, then releases the
  classification and asserts (via `confirmation(expectedCount: 0)`) it never
  appends. The production path now always runs through `UtteranceWindowRouter`, so
  the guard is both load-bearing and covered.
- Tail flush on `finish()` is fail-open and ordered (`finishFlushesPendingTailInOrder`).

**NOTE B (LOW, stop-time — already disclosed):** `finish()` appends the uncut tail
directly but `inner.finish()` clears the inner queue, so a window that was *cut and
queued/in-flight* when stop arrives is dropped while the later sub-threshold tail
is flushed — i.e. the final full second before stop can be lost out of order. Only
at stop, bounded to audio in flight, and disclosed verbatim in the run note's
"In-flight window dropped at stop". Acceptable; if ever tightened, flush inner's
pending chunks fail-open too. Not requested now.

**NOTE C (LOW, latency — undocumented):** ASR now receives audio in ~1 s batches
plus classification time instead of streaming per ~20–60 ms tap buffer, so Apple
Speech partial hypotheses update roughly once per second. This is an inherent cost
of window-level decisions and is a UX latency regression worth a one-line mention
in the run note's residual risks; it is not a correctness defect.

### 4. Local/offline-first preserved — YES
No new import, URLSession, socket, analytics, or model-download path in the W1 or
W2 diff. Classification stays on-device through `VoiceFilterPipeline` →
`LocalSpeakerIdentifier`. CLAUDE.md hard rule #1 and ADR 0002 intact.

### 5. UI / doc wording — clean
No UI strings changed. W2 run note states "No safety, certification, or
airworthiness claim is made" and W1 note "this is not a flight-safety guarantee
(ADR 0008)". No "safe/certified/guaranteed/never miss" claims in changed source or
docs. Compliant.

### 6. Test strength — strong; a regression would fail
8 `UtteranceWindowRouterTests` + 5 `SerialBufferRouterTests`, all deterministic via
gated-classifier actor doubles with continuation tokens (no sleeps/wall-clock). The
event-log and AsyncStream-order assertions would fail on eager-concurrent or
FIFO-violating regressions; `coherentPilotWindowIsDiscardedAsUnit` /
`transcribeWindowAppendsAllBuffersInOrder` pin all-or-none window application;
`subThresholdWindowIsNeverDiscarded` pins the no-discard-below-threshold invariant;
`classifierErrorAppendsWindowAsUnit` pins fail-open. The only behavior not pinned by
a test is the mixed-straddle drop in NOTE A — that is a property of the FluidAudio
embedding over real audio, not unit-testable at this seam, and is the reason VAD is
deferred rather than a coverage gap.

## Scope discipline
Reviewed exactly the serial-routing (W1) and utterance-window (W2) seams. No
broadening into replay fixtures, App Store, hardware validation, or model-pack UX.
Verdict requests no changes in this cycle; NOTE A is carried forward to the future
VAD slice, NOTE C is a suggested one-line doc addendum.

## Notes on tests
Tests verify behavior, not coincidence: serialization is proven by ordered start/
finish event logs, not timing; window unit-of-decision is proven by asserting all-
or-none append per chunk; the stop race is proven by a zero-count confirmation that
releases the classification *after* `finish()`. A genuine regression in FIFO,
all-or-none, fail-open, or post-finish append would turn the suite red.
