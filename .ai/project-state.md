# Dspeech - aviation cockpit / ATC transcription (iOS) - Runtime project state

> Updated by the `orchestrator` and `tech-lead` roles after every dispatch.
> Mirrors high-level state only; per-run summaries/handles live under `.ai/runs/`.

Project ID: `dspeech`
Task prefix: `[Dspeech]`
Canonical registry: `/home/user/projects/MyInfra/config/project-workspaces/projects.yaml`

## Current phase

Privacy-first, offline-first ATC/cockpit transcription. On `feat/local-pilot-voice-filter`
the local voice-filter core, the route-health model/monitor layer, **and** the
route-health capture UX are all landed. Next product work is real local speaker
identification and the surrounding model-pack / pre-ASR routing, plus a
replay/route validation kit and App Store readiness.

## Active branches

- `feat/local-pilot-voice-filter` — voice-filter core + route-health model/monitor
  + route-health capture UX. Open as draft PR [#2](https://github.com/daocism/dspeech/pull/2).
- `project-workspace-bootstrap-20260521` — AI memory skeleton (merged groundwork).

## Last successful run

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

1. **Real local speaker identification** — FluidAudio/CoreML-backed
   `LocalSpeakerIdentifier` replacing the deferred stub (ADR 0007), with the
   model-pack download/enable UX and pre-ASR audio routing so pilot suppression
   runs before STT, not just as a post-ASR callsign gate.
2. **Replay / route validation kit** — recorded-route + sample-audio harness so
   route-health and voice-filter behavior is verifiable without live hardware.
3. **App Store readiness** — privacy nutrition labels, on-device/offline
   messaging, screenshots, TestFlight build.

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
