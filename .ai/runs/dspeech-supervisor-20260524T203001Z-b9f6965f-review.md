# Review — pre-ASR audio-buffer routing gate recovery

- **Run ID:** `dspeech-supervisor-20260524T203001Z-b9f6965f`
- **Role:** reviewer (skeptical, read-only on source; no production files edited)
- **Date:** 2026-05-24
- **Branch reviewed:** `origin/feat/local-pilot-voice-filter` @ `1f39c86`
- **Feature commit under review:** `24dfbdf feat(voice-filter): gate apple speech buffers before asr`
  (+ `75d1be9` run-note sha, `1f39c86` tester-unit verification artifact)
- **Depends on:** tester-unit artifact `.ai/runs/dspeech-supervisor-20260524T203001Z-b9f6965f-tester-unit.md`
- **Verdict:** ✅ **APPROVE** — code is safe and fail-open; risk cases are test-pinned;
  no network/SPM/fake-AI added; privacy/local-only preserved. Follow-ups recorded below
  for the next builder cycle (none blocking this commit).

---

## What the change does

Introduces a `SpeechAudioBufferGate` seam so that, *once a real local speaker model
ships*, confidently-classified pilot speech can be discarded before Apple Speech ASR.
Today the seam is **inert in production** (never discards) and exists only to be wired.

- `LiveTranscriptionEngine.swift:25-57` — new `@MainActor protocol SpeechAudioBufferGate`,
  plus `AlwaysTranscribeSpeechAudioBufferGate` (test/null) and
  `VoiceFilterSpeechAudioBufferGate` (production seam, fail-open on classifier throw).
- `AppleSpeechLiveTranscriptionEngine.swift:99-179` — tap callback now routes each buffer
  through `appendThroughGate`; adds `nonisolated static monoFloatSamples`.
- `ContentView.swift:11-23` — constructs **one** `VoiceFilterPipeline` and shares it
  between the gate and the view model (and Settings via `_voiceFilter`).
- `VoiceFilterPipeline.swift:158` — `routeBeforeTranscription` now **transcribes**
  `.insufficientSpeech` (was discard), per `docs/eval/local-speaker-model-pack-validation.md`.
- `PilotVoiceProfile.swift:69` — adds `.classifierUnavailable` transcribe reason.

---

## Mission questions — answered

1. **Shared pipeline?** ✅ Yes. `ContentView.init` (`ContentView.swift:15-21`) builds
   `let filter = …` once and injects that *same instance* into
   `VoiceFilterSpeechAudioBufferGate(pipeline: filter)`, `LiveTranscriptionViewModel(voiceFilter: filter)`,
   and `_voiceFilter = State(initialValue: filter)`. Settings and the pre-ASR gate observe
   one pipeline — no split-brain enabled/profile/pack state.

2. **Fail-open coverage?** ✅ Every path falls open to ASR:
   - no gate injected → `AppleSpeechLiveTranscriptionEngine.swift:128-131` appends directly;
   - mono extraction fails (nil) → `:132-135` appends directly;
   - gate throws → `:148-150` catch appends directly;
   - classifier/pack/profile unavailable → `LiveTranscriptionEngine.swift:48-53` catches and
     returns `.transcribe(reason: .classifierUnavailable)`; `requireInstalledModelPack`
     (`VoiceFilterPipeline.swift:64-68`) throws when the pack is absent/disabled, and the
     default `UnavailableLocalSpeakerIdentifier` throws `.modelUnavailable`
     (`LocalSpeakerIdentifier.swift:44-58`). **In a default build nothing is ever discarded.**

3. **Only `.pilot` discarded?** ✅ `routeBeforeTranscription` (`VoiceFilterPipeline.swift:145-162`):
   `.pilot → .discard`; `.nonPilot`, `.mixed`, `.insufficientSpeech → .transcribe`; plus
   `guard enabled` and `guard !profiles.isEmpty` short-circuit to transcribe first.

4. **Any FluidAudio/WhisperKit/SPM/model-download/network added?** ✅ No. Commit `24dfbdf`
   touches no `project.pbxproj`, adds no `.package(`, `URLSession`, `dataTask`, or `download`.
   The only `https://` in added *code* is the `source: "https://mirror.invalid/voice-filter"`
   **test fixture** string (invalid TLD, never fetched). Other URL hits are doc/run-note prose.

5. **`@MainActor` seam acceptable as temporary?** ⚠️ Yes, **for now only** — see finding W1
   below. Acceptable because today the gate never performs heavy work and never suspends
   meaningfully (it fail-opens immediately), so buffer ordering is preserved. It is **not**
   acceptable once a real classifier lands.

6. **Prior-run workflow integrity?** See "Workflow findings" — two issues recorded.

---

## Findings (severity-ordered)

### W1 — MEDIUM (forward-looking, non-blocking): `@MainActor` gate must move off-main before a real classifier
`SpeechAudioBufferGate.route` is `@MainActor` and is invoked per audio buffer from the
realtime tap via `Task { @MainActor … await appendThroughGate(buffer) }`
(`AppleSpeechLiveTranscriptionEngine.swift:98-103`). Today `pipeline.classify` returns/throws
without a real suspension, so appends stay in order and the main thread is not loaded. The
moment a real FluidAudio-style embedding classifier is inserted, two regressions appear:
(a) heavy DSP/inference runs on `@MainActor`, blocking UI; (b) the `await` becomes a true
suspension point, so multiple in-flight buffer `Task`s can `request.append` **out of capture
order**, corrupting ASR. **Ask:** before wiring a real `LocalSpeakerIdentifier`, move
classification to a background actor/executor and guarantee FIFO append ordering (serial
queue or a single owning actor). This is the explicit ADR 0008 follow-up.

### W2 — MEDIUM (forward-looking, non-blocking): per-buffer discard granularity vs continuous ATC stream
The seam classifies and potentially discards individual ~1024-frame buffers. Real ATC audio
interleaves pilot readback and controller speech inside one continuous stream; dropping
sub-second buffers mid-utterance may fragment Apple Speech's recognition of the *following*
non-pilot speech. **Ask:** when the real identifier lands, validate that discard granularity
is utterance/segment-aware, not raw-buffer-level, before enabling discard in production.
Inert today (never discards), so not a current defect.

### T1 — LOW (test coverage gap): engine-level wiring is unverified
`SpeechAudioBufferGateTests` exhaustively pin the *decision* logic, but no automated test
exercises `appendThroughGate` itself — i.e. that `.discard` actually skips `request.append`,
that `.transcribe` appends, that a nil gate appends, and that nil-mono-samples appends. These
require `SFSpeechAudioBufferRecognitionRequest`/`AVAudioEngine` and are genuinely awkward to
unit test, so the gap is understandable; the risk-bearing logic (the decision) is fully
covered. **Ask:** consider extracting the append-vs-skip branch into a pure helper testable
without AVFoundation when the real classifier lands.

### I1 — LOW (informational, pre-existing): deferred buffer lifetime
`monoFloatSamples` reads `buffer.floatChannelData` pointers on a deferred `@MainActor` task,
after the tap block has returned. AVAudioEngine may recycle tap buffers; this lifetime
assumption pre-existed the change (the old code also deferred `request.append(buffer)` in a
`Task`), and the new code does not materially worsen it. Noted for awareness, not a blocker.

---

## Test-quality assessment

The mission's sharpest question — *"could `.mixed` / `.insufficientSpeech` still be silently
discarded without a failing test?"* — is answered **No**. `DspeechTests/VoiceFilterTests.swift`
(`SpeechAudioBufferGateTests`) contains direct behavior pins that would fail if anyone flipped
the routing to discard:

- `mixedTranscribes` → asserts `.transcribe(reason: .mixedOrLowConfidence)`
- `insufficientSpeechFailsOpenToASR` → asserts `.transcribe(reason: .insufficientSpeech)`
- `routeBeforeTranscriptionFailsOpenForInsufficientSpeech` → pins the changed pipeline branch
- `confidentPilotIsDiscardedBeforeASR` → the *only* `.discard` assertion
- `nonPilotTranscribes`, `disabledFilterTranscribes`, `noProfileTranscribes`
- fail-open: `absentPackFailsOpenToASR`, `disabledPackFailsOpenToASR`,
  `unavailableIdentifierFailsOpenToASR`, `thrownClassifierErrorFailsOpenToASR`
- `alwaysTranscribeGateNeverDiscards`
- `monoFloatSamples{ExtractsMonoFloat32,AveragesStereoChannels,NilForNonFloatFormat,NilForEmptyBuffer}`

These are real specifications (assert on exact reasons, not coincidences) — not §6
tests-pass-for-the-wrong-reason. Tester-unit artifact reports `** TEST SUCCEEDED **` on mac24
iPhone 17 Pro / OS 26.4 with these cases observed passing, run in a throwaway worktree to
avoid clobbering the dirty mac24 checkout (honest, careful handling). Coverage gap T1 above.

---

## Workflow findings (record for next builder cycle)

### F1 — Finalizer truthfulness: builder `0f54bfce` marked `Blocked` while its work landed healthy
The prior builder run (`dspeech-builder-20260524T190024Z-0f54bfce`) finalized Notion status
`Blocked` because `engineer-backend` exited `rc=1` and `tester-integration`/`reviewer` were
dependency-blocked. Yet that run's commits (`24dfbdf`, `75d1be9`) reached
`origin/feat/local-pilot-voice-filter` and pass `DspeechTests` green. The finalizer reported
run-orchestration failure as project failure without reconciling against repo reality. **Next
cycle:** finalizers should verify whether pushed commits are healthy before emitting a terminal
`Blocked` status, or distinguish "run aborted" from "work rejected."

### F2 — Role-scope: a `feat(...)` production commit was authored under the `tester-unit` identity
`24dfbdf` (production Swift: `ContentView`, `AppleSpeechLiveTranscriptionEngine`,
`LiveTranscriptionEngine`, `VoiceFilterPipeline`) is authored
`AI Office tester-unit <ai-office+tester-unit@daocism.local>`. tester-unit's contract is
tests/verification only. Either the recovery builder committed under a shared tester-unit git
identity (identity-mapping coarseness) or the role boundary was crossed. **Next cycle:** ensure
production code commits carry an implementer/engineer identity, not tester-unit, so authorship
audits remain meaningful. (Not a code defect; recorded for governance.)

### F3 — External state: active Notion task `369dfa2b…486a6` returns `NOT_FOUND`
Supervisor evidence and the run-note both note the active-task URL is unreachable from this
environment; the tester-unit artifact references a different run-page id
(`36adfa2b-7893-8188-a257-dd401d67f84a`). Notion is a read-model only (per CLAUDE.md) so this
does not gate code, but the canonical task page should be reconciled before the next cycle.

---

## Next builder-cycle recommendation

1. **Merge-ready as-is.** The pre-ASR seam is safe, inert in production, and well-tested. No
   source changes requested.
2. The next builder that wires a **real** `LocalSpeakerIdentifier` (ADR 0008) MUST first
   address **W1** (move classification off `@MainActor`, guarantee FIFO append ordering) and
   **W2** (utterance-aware discard granularity), and SHOULD close **T1** (testable
   append-vs-skip helper). Do not enable buffer discard in production until those land.
3. Record **F1/F2** as process fixes for the finalizer and role-identity mapping.

---

*Checklist passed:* security, correctness, trust (no hallucinated/unverified API; AVFoundation
+ SFSpeech usage matches Apple contracts), quality (fail-fast, no silent failures — all error
paths fail **open** by deliberate documented design), shape (single shared pipeline, single
caller, no premature abstraction), verification (mac24 `** TEST SUCCEEDED **`, risk cases pinned).
