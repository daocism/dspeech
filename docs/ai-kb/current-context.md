# Dspeech - aviation cockpit / ATC transcription (iOS) - Current Context

> Rolling 1-page pointer. Updated by `knowledge-curator` after every substantive run.

## READ FIRST (2026-06-12)

PR #3 "production-ready" was FALSE-READY: first human use broke the core flow (text
replaced at silence boundaries; filter semantics inverted vs owner intent). Incident +
self-retro: global memory `feedback_primary_scenario_proof`. The binding work now:
`docs/PLAN-2026-06-12.md` → `docs/SPEC-2026-06-12-core-semantics-rebuild.md`
(dispatcher-only durable transmission blocks, real-audio harness on the French ATC
fixtures, WhisperKit phase). Do not trust the previous "ready" claims below.

## What we are building right now

Native iOS 26+ SwiftUI app: receive-only cockpit/ATC live transcription, on-device only,
optional on-device translation. 2026-06-11: a 64-agent production-readiness review (163+7
findings) produced `docs/SPEC-2026-06-11-production-readiness.md`; remediation is being
executed in 4 waves on `fix/production-readiness-2026-06-11` (Claude = architect/reviewer,
Codex GPT-5.5 workers = implementation).

## Landed (waves 1-3, all suites green: 659 unit + 27 UI, zero warnings)

- **Session survival**: AVAudioEngineConfigurationChange rebuild, dead-engine honesty,
  interruption auto-resume, multicast route streams, fresh engine after media-services
  reset, foreground route refresh, keep-awake while listening (ADR 0010).
- **Audio session**: canonical `.playAndRecord` shared with routing (invalid
  `.duckOthers`/`.record` combo gone), AudioCaptureArbiter — dictation/enrollment/meter
  can no longer kill live capture.
- **Filter safety**: urgency bypass (MAYDAY/PAN PAN/SECURITE/ALL STATIONS — unsuppressible,
  opens continuation window), abbreviated-callsign DISPLAY tier (matchesAbbreviated,
  exact-run; strict matches() unchanged for suppression-grade logic), full ICAO phonetics,
  insufficientSpeech fails open everywhere.
- **Transcript = flight data (D4)**: FileTranscriptStore (JSONL, per-append flush, crash
  recovery, protected files), session history UI + share/export, auto-scroll + jump-to-live,
  Clear-with-confirmation (history retained), suppressed-segment review sheet, demo/hints
  retire after first real session.
- **ASR robustness**: restart taxonomy (1110/203/timeout/duration benign; loop guard),
  ~1s replay tail across task recycling, availability delegate, honest confidence (0 stays
  0; Stop placeholder is an explicit flagged state, never persisted), spoken-form callsign
  seeding, dictation locale+vocab parity.
- **Voice data**: voiceprints in protected backup-excluded file store (UserDefaults
  migration + wipe API), pinned HF revision downloads, disk-full taxonomy, voiced-duration
  enrollment gate, relative container paths.
- **Settings integrity**: locale survives capable-set narrowing, translation target never
  silently equals source, saves surface failures, preferred-input fallback applied.
- **Observability**: DspeechLog categories across the service layer; field failures
  reconstructable from `log collect`; no transcript/callsign/voiceprint content in logs.
- CI reworked for free-plan minutes (PR+main only, single build, caps, non-blocking flake
  report, failure artifacts). New app icon (tower→waves→AI→plane).

## Binding decisions

- ADR 0009: SFSpeechRecognizer stays (SpeechTranscriber lacks contextualStrings biasing);
  DictationTranscriber is the migration target at iOS 27 re-eval.
- ADR 0010: keep-awake, auto-resume, NO UIBackgroundModes audio without a superseding ADR
  signed by Andrei. F8 stop-on-background stands.
- Spec D1-D5 (docs/SPEC-2026-06-11-production-readiness.md) bind all remediation work.

## In flight (wave 4) + open tail

- W10: ContentView decomposition (≤800-line rule), iPad adaptivity, full l10n fill,
  privacy-toggle truthfulness. W11: scripted-engine seam, real-pipeline replay eval,
  PBT sweeps, no timing-window assertions. W12: warnings-as-errors, version xcconfig,
  script robustness, staged-only gitleaks hook, SHA-pinned actions.
- After wave 4: ko locale + listing-it/uk + release-policy locale check; final adversarial
  re-review cycles; device-verification lane remains the honest gap (run-on-device
  checklist: lock/call/cable-pull scenarios per ADR 0010) until a physical device session.
- Known accepted-for-now: replay-tail may rarely duplicate a word across task restarts
  (loss is worse than duplication for ATC) — quantify on the device replay corpus.
