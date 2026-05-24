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
