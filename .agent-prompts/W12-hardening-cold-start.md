# W12 — Hardening: cold-start instrumentation (OSLog signposts)

You are an **observability hardening implementer**. Branch:
`hardening/cold-start-2026-05-20` from `feat/mvp-completion-2026-05-19`.

## Mission
Wire OSLog signposts per `docs/ops/cold-start-instrumentation-spec.md` so that
on every cold launch we record: app-init, scenePhase=active, first-frame,
PrivacySettings load, FirstRunCoordinator decision, Speech permission ready,
Audio session activate, Translation availability query, first transcription
segment. Each signpost has a stable `Name` literal and end-event so Instruments
"Points of Interest" track can graph the launch.

## Pre-flight
1. Baseline branch + green test suite as in W10/W11.

## Work
- Centralise signpost in a single `Telemetry` enum with helper APIs
  `Telemetry.begin(.coldStartInit, id:)`, `Telemetry.end(.coldStartInit, id:)`.
- Use `os_signpost` via `OSLog(subsystem: "com.dspeech", category: .pointsOfInterest)`.
- Mark the spec's anchor points exactly (do not invent new ones in this wave).
- Wire `DspeechApp.init`, `ContentView.task`, ViewModel boot, AudioService open,
  TranslationLanguagePackManager query.
- Verify locally via `xcrun simctl spawn booted log stream --predicate 'subsystem == "com.dspeech"' --info` — capture a sample in `docs/ops/cold-start-2026-05-20-sample.log` (5-second window).

## Verification gates
1. `xcodebuild build test` = **PASS 88/0/0**.
2. `grep -rn "os_signpost\|Telemetry\." Dspeech/` ≥ spec's anchor count.
3. Sample log captured and committed.
4. No signpost name typos vs the spec.

## Output
- Atomic commits + push.
- `docs/handoff.md` `## W12 hardening-cold-start — 2026-05-20` with fields:
  `signposts_wired` (count), `sample_log_path`, `xcodebuild_test`, `ready_for_reviewer: yes`.
- `docs/NOTION-TASKS.md` row if any anchor was unreachable (defer reason).

## Anti-AI guards
- Zero PII in signpost arguments (`.private` for transcript / audio fields).
- No `print()` left from probing.
- Context7 for `os.signpost` API surface.
