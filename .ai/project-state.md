# Dspeech - aviation cockpit / ATC transcription (iOS) - Runtime project state

> Updated by the `orchestrator` and `tech-lead` roles after every dispatch.
> Mirrors high-level state only; per-run summaries/handles live under `.ai/runs/`.

Project ID: `dspeech`
Task prefix: `[Dspeech]`
Canonical registry: `/home/user/projects/MyInfra/config/project-workspaces/projects.yaml`

## Current phase

2026-07-02: **Night-polish mission** on `feat/night-polish-20260702` — 99-task plan
(docs/PLAN-2026-07-02-night-polish.md) executed by a multi-agent overnight run:
FluidAudio 0.15.4, installer dedup + WhisperKit integrity, resumable downloads,
interruption causes, Liquid Glass chrome (ADR 0013), iPad split shell, all 11 locales
confirmed, 969-test suite + snapshots + installer PBT, CI cron lanes. See
docs/ai-kb/current-context.md READ FIRST for the full inventory + the quiescence-gating
pattern. PR to main pending final gates.

## Previous phase (2026-06-12, superseded)

2026-06-12: **Core-semantics rebuild** — see docs/PLAN-2026-06-12.md +
docs/SPEC-2026-06-12-core-semantics-rebuild.md (owner-approved). PR #3 merged but was
false-ready (D-1 text loss at restarts, D-2 inverted filter semantics). Definition of
done is now the real-audio harness over DspeechTests/Fixtures/ATC/*.wav. Tooling for the
session: XcodeBuildMCP + sosumi (.mcp.json), serena (settings.local.json).

## Previous phase (2026-06-11, superseded)



2026-06-11: **Production-readiness remediation** on `fix/production-readiness-2026-06-11`.
64-agent ultra-review (163+7 findings) → `docs/SPEC-2026-06-11-production-readiness.md`
(14 WPs, decisions D1-D5, ADR 0009/0010). Waves 1-3 LANDED and green (659 unit + 27 UI,
zero warnings): session survival + arbiter, filter urgency/abbreviation safety, transcript
persistence + history + cockpit UX, observability, ASR robustness, voice-data protection,
settings integrity. Wave 4 in flight (decomposition/iPad/l10n, test honesty, build/CI).
Execution model: Claude orchestrates/reviews/commits; Codex GPT-5.5 workers implement.
Open tail: ko locale + it/uk listings, final adversarial cycles, DEVICE verification lane
(lock/call/cable scenarios per ADR 0010) before any TestFlight claim. See
docs/ai-kb/current-context.md for the rolling 1-pager.

## Previous phase (2026-06-02, superseded)


2026-06-02: **MVP feature-completion** on `feat/mvp-completion-2026-06-02` (5 commits,
suite green, 0 warnings, device-arch compiles). Closed PRD gates §3 first-run onboarding,
F8 background ASR stop, F3 on-device translation (Apple Translation framework, local-only),
F5 audio source picker (per-device persistence). Two adversarial review passes; all
confirmed findings fixed. Remaining before TestFlight: device signing (Andrei's Apple ID/
Team) + ADR 0008 network-deny/replay kit + App Store metadata. Deferred polish (documented
in `docs/run-notes/2026-06-02-mvp-completion-translation-audio-onboarding.md`): F5 level
meter, in-app translation-unavailable surfacing.

Privacy-first, offline-first ATC/cockpit transcription. On `feat/local-pilot-voice-filter`
the local voice-filter core, the route-health model/monitor layer, the route-health
capture UX, a real offline FluidAudio speaker identifier, and the pre-ASR routing seam
(W1 serial FIFO routing + W2 utterance-window discard granularity) are all landed.
Next product work is VAD/silence-gap utterance segmentation (replacing the fixed 1.0 s
decision window), the ADR 0008 network-deny integration test + replay/route validation
kit, and App Store readiness.

## Active branches

- `feat/local-pilot-voice-filter` — voice-filter core + route-health model/monitor
  + route-health capture UX. Open as draft PR [#2](https://github.com/daocism/dspeech/pull/2).
- `project-workspace-bootstrap-20260521` — AI memory skeleton (merged groundwork).

## Last successful run

2026-05-26 (builder run `dspeech-builder-20260526T110023Z-29c9c067`):
**W2 — utterance-aware pre-ASR pilot suppression — LANDED and reviewer-approved.**
The pre-ASR discard decision moved from raw-tap-buffer level to a coherent ~1.0 s
**utterance window**, so a single mislabeled tap buffer can no longer punch a hole in
an ATC utterance. New `Dspeech/Core/ASR/UtteranceWindowRouter.swift` accumulates tap
buffers until `minimumChunkSamples` (`recordingFormat.sampleRate × 1.0 s`), classifies
the whole concatenated window once, and applies that one decision to every member
buffer as a unit (append-all or discard-all); sub-threshold windows are never
classified and are flushed fail-open on `finish()`. It wraps the unchanged W1
`SerialBufferRouter<[Buffer]>`, so the off-`@MainActor` / FIFO / fail-open-on-throw /
no-append-after-stop guarantees are reused, not reimplemented.
`AppleSpeechLiveTranscriptionEngine` now feeds this window router.
SHAs: contract `2ce3570` → feat `aee9c8c` → test-evidence `d3d95ad` → tester-unit
verification `90dc4d8` → reviewer `977d5a4` (origin tip `977d5a4`, this docs commit
sits on top). Tests: full `DspeechTests` on mac24 (iPhone 17 Pro / iOS 26.4),
`-only-testing:DspeechTests` → **`** TEST SUCCEEDED **`**; 8 new
`UtteranceWindowRouterTests` (C1–C6 coverage) + the 5 W1 `SerialBufferRouterTests`
regression guard + the rest of the domain suite all green. Tester-unit verdict: **PASS,
does not block merge**; confirmed zero audio-egress (no URLSession/socket/cloud in the
W2 diff). Reviewer verdict: **APPROVE_WITH_NOTES** — no change requested this cycle.
Non-blocking notes carried forward: NOTE A (MEDIUM, already disclosed) the fixed-1.0 s
window is not VAD/silence-segmented, so a window straddling a pilot→dispatcher
transition scoring ≥ `pilotMatchThreshold` (0.72) can discard up to ~1 s of co-located
dispatcher speech — the reason VAD segmentation is the next slice; NOTE B (LOW) a window
cut/in-flight at `finish()` is dropped while the later sub-threshold tail is flushed
(bounded to audio in flight at stop, disclosed in the run note); NOTE C (LOW) ASR now
receives ~1 s batches so Apple Speech partials update ~once/second (latency, not
correctness). Notion task `369dfa2b-7893-814c-be7e-e7cea26486a6`: **Notion NOT_FOUND** —
no connector reachable from the run environment (same as CEO inspection); repo run-notes
+ commit SHAs are the canonical handoff. Evidence:
`docs/run-notes/2026-05-26-utterance-window-pre-asr.md` (engineer),
`docs/run-notes/2026-05-26-tester-unit-utterance-window-pre-asr.md` (tester),
`.ai/runs/dspeech-builder-20260526T110023Z-29c9c067-reviewer.md` (reviewer),
`.ai/runs/dspeech-builder-20260526T110023Z-29c9c067-researcher-codebase.md` (contract).

2026-05-25 (workflow audit, run `dspeech-supervisor-20260525T203100Z-a08f1596`):
**Builder run `dspeech-builder-20260525T190042Z-c2188fe3`'s `Blocked` finalizer is a
workflow false-negative, not a product/test failure.** `qa-manual` confirmed a pristine
canonical checkout (clean tree, on-branch, 0/0 divergence), then hit a transient Claude
API `500 Internal server error` before writing its QA artifact — so it exited `rc=1` and
the finalizer flagged `Blocked`. The slice it covered (offline FluidAudio speaker
identifier behind the installed model-pack gate) is landed at `2d2da3e`, independently
verified green by tester-unit (full `DspeechTests`, 184/184, iPhone 17 Pro / iOS 26.4),
and pushed at `89495cc`. Branch is clean, 0/0 divergence from origin. Notion `NOT_FOUND`
for task `369dfa2b…26486a6` is a read-model/connector reachability issue, not lost state
(repo is canonical). Doc-only; no code change warranted. Evidence:
`.ai/runs/dspeech-supervisor-20260525T203100Z-a08f1596-workflow-audit.md`.

2026-05-25 (reconciliation, run `dspeech-builder-20260525T190042Z-c2188fe3`):
**Branch confirmed coherent around the landed offline FluidAudio speaker-identifier
slice** — no surgery needed. The engineer-backend worktree started at `a8a643d`, a
strict ancestor of `origin/feat/local-pilot-voice-filter` (`4fe4a44`) with zero
local commits ahead and a clean tree; origin is a clean fast-forward superset
(no `git reset --hard`, no dirty/staged state to recover — the two researcher input
artifacts named in the brief did not exist). Source at `4fe4a44` verified to satisfy
the accepted slice contract: default build fails open to
`UnavailableLocalSpeakerIdentifier`; `FluidAudioBackendBuilder` fails closed on
missing model path / missing `pyannote_segmentation.mlmodelc` / `wespeaker_v2.mlmodelc`
/ dimension mismatch / load error; `FluidAudioSpeakerIdentifier` uses the real offline
`DiarizerModels.load` + `extractSpeakerEmbedding` API; `VoiceFilterPipeline`
classifies before ASR and discards only confident `.pilot` speech; flight-safety
disclaimer intact (ADR 0008). Doc-only commit: corrected the stale
`UnavailableLocalSpeakerIdentifier`-is-the-only-conformer claim in
`docs/ai-kb/current-context.md`. Evidence + handoff:
`docs/run-notes/2026-05-25-fluid-audio-reconciliation.md`;
recovery decision: `.ai/runs/dspeech-builder-20260525T190042Z-c2188fe3-canonical-recovery.md`.

2026-05-25: **Voice-filter feature made functional end-to-end** on
`feat/local-pilot-voice-filter` (commits `1d8ce83`..`1375e09`). Fixes a launch
bug where Start was permanently disabled (route health read `.noInput` before any
record category was set — `RouteHealthClassifier` now falls back to a usable
available input and `LiveAudioSessionRouting` primes `.playAndRecord`); reflows
the control bar so the "Dspeech" title no longer wraps; adds on-device voice
dictation of the aircraft callsign (`CallsignDictationService` +
`PhoneticCallsignParser`, ICAO/aviation digit mapping). Completes the deferred
ADR 0007/0008 FluidAudio path: corrects the adapter to the real
`extractSpeakerEmbedding`/offline `DiarizerModels.load` API (it never compiled
against the resolved package), adds `SpeakerModelPackInstaller`
(`DiarizerModels.downloadIfNeeded` → real `.absent→downloading→installed` with
the ~13 MB pyannote+wespeaker_v2 pack, recursive model-dir locate), wires the
previously hard-disabled download CTA, lets `VoiceFilterPipeline` hot-swap its
identifier on install, and enrolls real pilot voiceprints via
`VoiceEnrollmentRecorder`. Verified on iPhone 17 Pro / iOS 26.4: cold download
installs and reaches the installed state; DspeechTests + Start/download UI tests
green. Still open per ADR 0008: a dedicated network-deny integration test and
replay-fixture eval lane before TestFlight.

2026-05-24: Pre-ASR **routing gate** landed and independently verified on
`feat/local-pilot-voice-filter`. Code commit `24dfbdf feat(voice-filter): gate
apple speech buffers before asr` adds a `SpeechAudioBufferGate` seam
(`AlwaysTranscribeSpeechAudioBufferGate` no-op + `VoiceFilterSpeechAudioBufferGate`)
so that, *once a real local speaker identifier ships*, confidently-classified pilot
speech can be discarded before Apple Speech ASR; everything uncertain still
transcribes. `ContentView` now shares one `VoiceFilterPipeline` instance across the
gate, the view model, and Settings (no split-brain state).
`routeBeforeTranscription` returns `.transcribe(reason: .insufficientSpeech)` for
`.insufficientSpeech` (was `.discard`), and a new `.classifierUnavailable` reason
fail-opens every classifier/pack/profile error path to ASR. Adds 16
`SpeechAudioBufferGateTests` cases.

Independent recovery verification (run `dspeech-supervisor-20260524T203001Z-b9f6965f`):
- tester-unit (`1f39c86 docs(ai): verify pre-asr routing gate recovery`) ran the
  full `DspeechTests` suite on mac24 (iPhone 17 Pro / iOS 26.4) in a throwaway
  detached worktree at the pushed head → `** TEST SUCCEEDED **`. All 13 suites
  green, including the new `SpeechAudioBufferGateTests`. Artifact:
  `.ai/runs/dspeech-supervisor-20260524T203001Z-b9f6965f-tester-unit.md`.
- reviewer (`5ee3841 docs(ai): review pre-asr routing gate recovery`) → **APPROVE**:
  safe, fail-open by design, risk cases test-pinned, no network/SPM/fake-AI added,
  privacy/local-only preserved. Two forward-looking non-blocking asks for the next
  builder cycle (W1: move classification off `@MainActor` + guarantee FIFO append
  order before a real classifier lands; W2: utterance-aware discard granularity).
  Artifact: `.ai/runs/dspeech-supervisor-20260524T203001Z-b9f6965f-review.md`.
- **W1 CLEARED** (`541353d`, 2026-05-26): `SerialBufferRouter<Buffer>` classifies
  off `@MainActor` (nonisolated identifier behind the gate) and applies
  append/discard strictly in capture/FIFO order; `AppleSpeechLiveTranscriptionEngine`
  submits tap buffers to it, fails open on classifier error, and `finish()` on
  cleanup blocks post-stop appends into a released request. `** TEST SUCCEEDED **`
  on mac24. W2 (utterance-aware discard) still open.
  Note: `docs/run-notes/2026-05-26-pre-asr-serial-routing.md`.

Honest limitation: there is still **no real local speaker identifier**. The only
`LocalSpeakerIdentifier` conformer is `UnavailableLocalSpeakerIdentifier`, which
throws `.modelUnavailable`. So the pre-ASR gate is **correct but inert / fail-open**
in a default build — every buffer transcribes because the classifier is always
unavailable. The gate only starts discarding pilot speech once the model-pack
backend (ADR 0008) ships a working identifier.

Workflow caveat: the builder run that authored this code
(`dspeech-builder-20260524T190024Z-0f54bfce`) finalized `Blocked` (Notion page
`36adfa2b…c822` set `Blocked`) because `engineer-backend` exited `rc=1` and the
dependent `tester-integration`/`reviewer` were dependency-blocked — yet `24dfbdf`
and `75d1be9` had already reached `origin/feat/local-pilot-voice-filter` and pass
green. This recovery run supplies the missing independent tester + reviewer
evidence the failed finalizer never gathered. (Also recorded: `24dfbdf`, a `feat()`
production commit, was authored under the `tester-unit` git identity — a role-scope /
identity-mapping issue flagged for governance, not a code defect.)

2026-05-24: Model-pack **execution gate** landed on `feat/local-pilot-voice-filter`
via `3dfc246 fix(voice-filter): gate speaker model execution`. `VoiceFilterPipeline`
now calls a private `requireInstalledModelPack()` before `identifier.enroll` and
`identifier.classify`, throwing `LocalSpeakerIdentifierError.modelUnavailable` unless
`modelPackState.isInstalled` — so an *available* identifier can no longer enroll/classify
while the pack is `.absent`/`.acquiring`/`.failed`/`.disabled` (ADR 0008 installed-only
contract). `decide(...)` and the callsign text gate are unchanged. Adds
`ModelPackStateStorageTests` (7: round-trip absent/installed/failed/disabled, acquiring→absent
cold-start recovery, missing/corrupt→absent) and 7 new `VoiceFilterPipelineTests` gate cases.
Verified on mac24 (iPhone 17 Pro / iOS 26.4): `-only-testing:DspeechTests` → `** TEST SUCCEEDED **`;
full DspeechTests suite green. mac24's unrelated dirty files were preserved (ff-merge only).
`DspeechUITests` not run this slice.

2026-05-24: Route-health **capture UX** landed on `feat/local-pilot-voice-filter`
via `b671f74 feat(audio): surface route health in capture UI`. A new
`@Observable CaptureCoordinator` seam wires `RouteHealthMonitor` into
`ContentView`: route-health chip (`route-health-chip`) + route-change banner
(`route-banner`), Start gated on `RouteHealthMonitor.blocksStart` (`.noInput`
only), and an external→built-in route loss stops live transcription instead of
silently continuing on the iPhone mic — making the «Запись приостановлена» copy
true. Adds `CaptureCoordinatorTests` (8 cases). This resolved the two HIGH
reviewer findings (no-UX-surface, banner over-claim) from run
`dspeech-builder-20260523T190026Z-8ff9dfb0`, whose finalizer had mistakenly marked
the run BLOCKED after the fix already landed; corrected in
`docs/run-notes/2026-05-23-route-health-ux.md`. Tester caveat: no fresh
`…-20260524…-verification.md` artifact was emitted this run and the 8
`CaptureCoordinatorTests` are not yet independently verified green in a recorded
run (mac24 reachable but pinned pre-wiring at `bdef438` with another worker's
in-flight changes); prior pre-wiring baseline at `bdef438` was 105/105 unit green.

2026-05-23: Route-health model/monitor layer landed (`RouteHealthClassifier`,
`AudioSessionRouting` protocol, `@Observable RouteHealthMonitor`); 105 unit tests
green on mac24 (iPhone 17 Pro / iOS 26.4), AVFAudio isolated behind the protocol.

2026-05-22: Local pilot voice-filter core landed: enrollment stores voiceprint +
callsign, pre-STT pilot suppression route, mixed-speaker safe transcribe policy,
ATC callsign/continuation gate indicators, mac24 simulator tests passed.

2026-05-21: Mr.Dao/tech-lead Project Workspace bootstrap rendered `.ai/` and
`docs/ai-kb/`, updated `AGENTS.md` / `CLAUDE.md`, verified docs-only diff hygiene.

## Remaining highest-leverage product work

1. **VAD / silence-gap utterance segmentation** — replace the fixed 1.0 s
   `decisionWindowSeconds` window boundary in `UtteranceWindowRouter` with a
   silence-gap-segmented boundary so a decision window no longer straddles a
   pilot→dispatcher PTT transition. This is the direct fix for reviewer NOTE A
   (the only substantive carry-forward) and tightens utterance boundaries before
   discard is enabled in production. The model-pack acquisition UX past the current
   download CTA / enrollment surface still needs hardening alongside this.
2. **ADR 0008 network-deny integration test + replay / source-audio validation
   kit** — a network-deny test proving zero egress under load, plus a fixture
   harness that feeds recorded ATC source audio through the ASR + filter pipeline so
   transcription/filter quality (and the W2 straddle case) is regression-testable
   without aircraft hardware. Required before enabling discard in production.
3. **App Store readiness** — privacy nutrition labels, on-device/offline
   messaging, screenshots, TestFlight build — only after 1 + 2 yield a real
   installable local build.

All of the above stay privacy-first and offline-first. No flight-safety
certification is claimed and none is implied; route-health is advisory.

## True external blockers (not approval theater)

These are the only things that genuinely gate progress — everything else is
buildable now:

- Apple Developer / TestFlight credentials (for device builds + App Store).
- A physical iPhone + real external ATC audio input hardware (for device smoke
  of the route-health chip / Start gate / external-loss pause).
- Real-world ATC sample audio (for replay-kit fixtures and voice-filter tuning).
- mac24 Claude login, *only if* direct mac24 AI workers (not ubuntu-vm→mac24 SSH)
  are required for a given run.
