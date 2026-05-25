# Reviewer verdict — pre-ASR gate hardening + supervisor workflow recovery

- **Run id:** `dspeech-supervisor-20260525T203100Z-a08f1596`
- **Role:** reviewer (distinct-skeptical persona; ubuntu-vm worktree, no mac24 Claude)
- **Date:** 2026-05-25
- **Base:** `89495cc` (`docs(run-notes): tester-unit verification of FluidAudio speaker-identifier slice 2d2da3e`)
- **Reviewed:**
  - slice — `origin/fix/pre-asr-serial-buffer-routing` (`f39d8f6` fix + `3064e97` tester-unit note)
  - workflow recovery — `origin/feat/local-pilot-voice-filter` (`2165900` workflow audit + `.ai/project-state.md`)

## VERDICT: APPROVE WITH NON-BLOCKING RISKS

The pre-ASR serialization change is correct, fails open exactly where the product
requires, suppresses ASR feed only for a confident pilot match, adds no network egress,
and is covered by deterministic tests that would fail under the old per-buffer-`Task`
model. The workflow audit's `Blocked`→false-negative reconciliation is evidence-backed,
cites SHAs/streams, creates no duplicate Notion task, and warrants no code change.
Nothing here is a true user-side blocker. Four non-blocking risks are recorded below;
all are pre-existing or already named as the next priorities (reviewer W1/W2, replay kit).

---

## Findings (ordered by severity)

### MEDIUM — unbounded `AsyncStream` buffering while classification is still `@MainActor`
`Dspeech/Core/ASR/LiveTranscriptionEngine.swift:73` — `AsyncStream<Element>.makeStream()`
uses the **default unbounded buffering policy**. The realtime capture tap
(`AppleSpeechLiveTranscriptionEngine.swift:113` `queue.submit(...)`) yields from the
audio thread, but the consumer routes via `await route(element)` and classification
(`VoiceFilterPipeline.classify`, `SpeechAudioBufferGate`) is still `@MainActor` — the
run-note explicitly defers off-main classification (reviewer W1) as out of scope.
Consequence: if classify latency exceeds the buffer cadence, the stream's unbounded
buffer grows without backpressure, each element retaining an `AVAudioPCMBuffer` →
unbounded memory growth + growing transcript latency under load. This is **not a
regression** (the prior per-buffer `Task` model accumulated Tasks the same way), and the
serialization boundary delivered here is the correct first step. **Ask:** before discard
goes live in production, decide a bounded buffering policy (`.bufferingNewest(n)` /
drop-oldest) *and/or* land the off-main classification W1 follow-up, and add a test that
asserts behavior when the consumer falls behind. Not blocking for this doc-and-plumbing
slice.

### LOW — raw-buffer-level discard, not utterance-aware
`Dspeech/Core/VoiceFilter/VoiceFilterPipeline.swift:163` — `.pilot → .discard`. Discard
is decided per ~1024-frame capture buffer. A confident pilot match suppresses that single
buffer's ASR feed; the routing is correct and only confident `.pilot` discards (`.nonPilot`,
`.mixed`, `.insufficientSpeech` all fail open to `.transcribe`), so **no confident ATC is
suppressed**. The risk is granularity, not direction: buffer-level gating can clip a word
boundary mid-utterance. Already named as reviewer **W2** ("make discard utterance-aware")
in the workflow audit's next-priority list. **Ask:** confirm W2 lands before production
discard; no change needed in this slice.

### LOW — `SendableAudioBuffer` retains the tap buffer across the thread hand-off
`AppleSpeechLiveTranscriptionEngine.swift:277` — `@unchecked Sendable` box carries the
`AVAudioPCMBuffer` from the realtime tap to the main-actor consumer, where
`monoFloatSamples`/`request.append` read it after an `await`. Correctness relies on
`AVAudioEngine.installTap` allocating a fresh buffer per callback (true in practice) rather
than recycling one. This is **pre-existing** — the prior `Task { await appendThroughGate(buffer) }`
deferred the same buffer across a main-actor hop identically — so the change preserves, not
introduces, the assumption. The `@unchecked Sendable` box is documented and narrow.
**Ask (optional hardening):** if you ever observe corrupted/duplicated audio, copy samples
inside the tap before submitting. Not blocking.

### LOW — no telemetry/counter for discarded buffers; replay path not yet exercised
The discard happens at the ASR feed only — it does **not** destroy any source-audio
recording, because no source-audio/replay capture path exists yet (it is priority 2,
"replay/source-audio validation kit"). So the "source audio remains canonical for
debugging" guardrail is **not violated** by this change. However, there is currently no
count/log of how many buffers were discarded, which will matter when tuning the filter
against real ATC audio. **Ask:** fold a discarded-buffer counter into the replay-kit work
(priority 2). Not blocking.

---

## Product guardrails — verified

| Guardrail | Result | Evidence |
|---|---|---|
| Default / unavailable classifier fails open to transcription | PASS | `routeBuffer` returns `.transcribe` for nil gate, nil samples, and thrown classifier (`AppleSpeechLiveTranscriptionEngine.swift:165-181`, `// why: fail open`); `VoiceFilterSpeechAudioBufferGate.route` catches classify throw → `.transcribe(reason: .classifierUnavailable)` (`LiveTranscriptionEngine.swift:50`); tests `noGateRoutesTranscribe`, `unsupportedSampleFormatRoutesTranscribe`, `thrownClassifierErrorRoutesTranscribe` |
| No confident ATC / non-pilot audio silently suppressed | PASS | `routeBeforeTranscription` discards **only** `.pilot`; `.nonPilot`/`.mixed`/`.insufficientSpeech` → `.transcribe` (`VoiceFilterPipeline.swift:162-170`); tests `nonPilotRoutesTranscribe`, `confidentPilotRoutesDiscard` |
| Local / offline-first remains true | PASS | code diff adds only `AsyncStream`/serial-queue plumbing; grep `URLSession|http|upload|network|socket` over `Dspeech/**` diff → none |
| No flight-safety / certification guarantee introduced | PASS | grep `certif|FAA|approved for|flight.safe` over diff → only software-ordering "guarantee" wording, no airworthiness claim |
| Source audio / replay remains canonical for debugging | PASS (see LOW note) | discard gates the `SFSpeechAudioBufferRecognitionRequest` feed only; no recording/replay path is removed (none exists yet) |

## Workflow guardrails — verified

| Guardrail | Result | Evidence |
|---|---|---|
| Worker used `dspeech` base repo, not MyInfra | PASS | artifacts reference `git@github.com:daocism/dspeech.git`, mac24 `/Users/andre/projects/dspeech-ios`; grep `myinfra` over both run artifacts → none |
| mac24 used only for deterministic commands | PASS | tester-unit note: `git status --porcelain`, `git fetch`, `git worktree add --detach`, `xcodebuild … build test`, `git worktree remove`; workflow audit ran "ubuntu-vm worktree; no mac24 Claude" |
| Artifacts cite commits/tests, claim no missing evidence | PASS | tester-unit cites SHA `f39d8f6`, `** TEST SUCCEEDED **`, 193 pass / 0 fail, names both new suites; **cross-check: 184 (prior, per workflow audit) + 9 new (4 `SerialAudioRoutingQueueTests` + 5 `AppleSpeechRoutingTests`) = 193** — internally consistent, not fabricated; workflow audit attributes `Blocked` to `api_error_status:500` from `qa-manual.jsonl`, not a defect |
| No duplicate Notion task created after `NOT_FOUND` | PASS | workflow audit records task `369dfa2b…26486a6` `NOT_FOUND` as read-model/connector reachability per `docs/ai-kb/current-context.md` (Notion = read model only); states "No duplicate task was created" — consistent with constraint |

## Tests — skeptical re-read

`DspeechTests/VoiceFilterTests.swift` (+153, additive). `preservesCaptureOrderWhenEarlierElementRoutesSlower`
is the load-bearing test: earlier elements `Task.yield` more, so under the old
independently-scheduled per-buffer `Task` they could be overtaken — it asserts strict
`[0,1,2,3]` order, i.e. it pins the exact regression the slice fixes and would fail on the
old code. `submitAfterFinishIsIgnored` covers the teardown race (`finish()` before
`request=nil`). `AppleSpeechRoutingTests` drive real `AVAudioPCMBuffer`s through
`routeBuffer` for every fail-open branch + the single discard branch. Deterministic
(spin/`Task.yield`, no clock/network/randomness). Tests verify behavior, not coincidence;
none were weakened.

## Independent verification boundary

I did **not** re-run `xcodebuild` — it requires mac24 Xcode, and the reviewer scope is the
diff + artifacts, not a second deterministic build. The 193-test claim is accepted on the
strength of (a) the internally-consistent 184+9 arithmetic and (b) the per-suite green
listing in the tester-unit note. If a fresh deterministic build is desired before merge,
re-run the CLAUDE.md `xcodebuild … build test` over `ssh mac24` (deterministic, allowed).

## Next worker action

None required to clear this verdict. To close the W1/W2 hardening track before production
discard: (1) bound the routing-queue buffering policy and/or move classification off
`@MainActor` (reviewer W1, MEDIUM above), (2) make discard utterance-aware (reviewer W2),
(3) build the replay/source-audio kit with a discarded-buffer counter (priority 2), and
add the ADR 0008 network-deny integration test named in the audit.
