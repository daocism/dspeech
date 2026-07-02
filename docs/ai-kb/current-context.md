# Dspeech - aviation cockpit / ATC transcription (iOS) - Current Context

> Rolling 1-page pointer. Updated by `knowledge-curator` after every substantive run.

## READ FIRST (2026-07-02) — night-polish mission

**Branch `feat/night-polish-20260702`** (99-task plan: `docs/PLAN-2026-07-02-night-polish.md`,
~95% executed overnight by a multi-agent run; PR pending). Landed highlights:

- **Deps**: FluidAudio → exact **0.15.4** (semantic audit: StreamingEouAsrManager contract
  unchanged, reset-after-EOU holds; SpeakerEval lockstep; release-policy updated). New:
  swift-collections (Deque in SerialBufferRouter), swift-async-algorithms (partial-text
  throttle), swift-snapshot-testing + PropertyBased (test target).
- **Dedup**: generic ModelInstallSupport engine (3 installer stacks single-sourced,
  UserDefaults keys byte-stable), ApplicationSupport helper (8× `.first!` gone),
  AVAudioEngineTapSession (4 capture wrappers share the format-nil/@Sendable tap core),
  WhisperKit installer got per-file SHA-256 (17 pinned hashes — fail-open gap closed).
- **Features**: file-granular resumable downloads (+pause/resume UX, offline taxonomy),
  interruption-cause classification (call/mic-muted/route), JSONL export, session
  duration/engine/locale metadata, storage footprint + opt-in retention cleanup,
  Parakeet installer UI localized (C9).
- **UI (ADR-0013)**: iOS 26 Liquid Glass on all chrome (controls/chips/banners/bubbles/
  pill; cards stay opaque), two-tier badges, typography (single mono register), haptics,
  card entrance transitions, dark+tinted app icons, **iPad NavigationSplitView shell**
  (sidebar Live/History/Settings; no letterbox; phone layout untouched).
  CRITICAL PATTERN: `.interactive()` glass / ungated animations stall XCUITest quiescence —
  every decorative motion must gate on `reduceMotion || DecorativeMotion.isDisabledForUITests`
  (the scripted-flow test is the canary; it caught this live).
- **l10n**: ALL 11 locales fully confirmed (1792 needs_review cleared, 268 fixes; pt unified
  to pt-BR — flip available; register/terminology unified per locale).
- **Tests**: 969 unit (incl. PropertyBased installer PBT with reach gates, 32 pinned
  snapshots host-gated to mac24), VoiceFilterTests split into 7 files, new UI tests
  (translation+scripted, permission deep-link — caught a real a11y identifier-propagation
  bug on the glass banner, dark-lock, VoiceOver expand), ru a11y sweeps added.
- **CI**: weekly full-a11y cron + monthly speaker-calibration, toolchain-version artifact,
  snapshot failure diffs uploaded; pre-push device-arch hook; scripts/local-gate.sh.
- **Tools symlink rule**: ReplayKit/SpeakerEval vendor Core by SYMLINK — any NEW Core file
  used by shared code must be symlinked into BOTH packages or the host CLIs break
  (caught by the real-audio gate tonight; `--source-only` policy does not compile Tools).
- **Store prep**: privacy-policy DRAFT (publishing = owner call), SDK manifest audit clean
  (Xcode 26 dropped `privacyreport` CLI — aggregation done directly), listing metadata
  linter green over 11 listings, release checklist refreshed, README rewritten.

Owner-decision items untouched per plan: background audio (ADR 0010), monetization
(ADR 0003), ATCVoiceIndicator badges, CDN mirror, paid Developer Program, privacy URL
publication, pt-PT vs pt-BR confirmation.

## READ FIRST (2026-06-23)

**Parakeet EOU is now the third ASR engine** (`feat/parakeet-third-engine`, ADR-0012
LANDED). Three-engine roster: **Apple SFSpeechRecognizer = default** (ADR-0009/0011,
unchanged), **WhisperKit = multilingual selectable** (ADR-0011), **Parakeet EOU 120M
streaming (FluidAudio) = English-only selectable** (ADR-0012). Default policy unchanged —
Parakeet is selectable, never auto-selected.

Landed (atomic, behavior-preserving until the UI commit; full DspeechTests suite green,
852 tests):
- `ParakeetStreamingAdapter.swift` — `ParakeetLiveStreaming` protocol + actor bridge over
  `FluidAudio.StreamingEouAsrManager` (160ms chunks). Protocol is AVAudioPCMBuffer-free so
  tests substitute a fake without importing FluidAudio. NOTE: FluidAudio `reset()` is `async`
  but NOT throwing — `try` there is a warnings-as-errors build break.
- `ParakeetLiveTranscriptionEngine.swift` — `LiveTranscriptionEngine` driven by FluidAudio's
  partial + EOU callbacks. English-only locale gate (`!hasPrefix("en")` → `.failed`), model-
  not-installed guard, generation-guarded `@Sendable` callbacks that hop to MainActor before
  touching state. EOU segments carry **confidence 0** (honest unknown — the streaming callback
  yields text only, no confidence; `requiresVerification` is therefore true) and **speaker nil**
  (FluidAudio's streaming API exposes no per-utterance sample window for the voice-filter gate,
  unlike WhisperKit which holds the decode window). Both are deliberate, documented in-code; the
  `bufferGate` is wired for API parity but not consulted for classification this round.
- `ParakeetModelInstaller.swift` — pinned HF rev `40a23f4c`,
  `FluidInference/parakeet-realtime-eou-120m-coreml`, 160ms variant (16 files), staged to
  `Application Support/FluidAudio/Models/parakeet-realtime-eou-120m-coreml/160ms/`. **Supply-chain
  upgrade vs the WhisperKit installer**: each file carries a baked-in SHA-256 and is verified
  post-download; a mismatch throws `checksumMismatch`, tears down staging, never installs (no
  fail-open). `expectedFiles` is injectable ONLY so tests can drive the verification path with
  content they control (real model bytes can't be reproduced from a fake downloader).
- Wiring: `TranscriptionEngineChoice.parakeet` (forward-only migration via the existing
  unknown→.apple fallback); ContentView engine factory `.parakeet` arm (falls back to Apple when
  the pack isn't installed); SettingsView picker offers Parakeet only for en-* locales (hidden
  otherwise; switching to non-en while selected resets to Apple) + a model-install section.

Adversarial self-review (two passes) found + fixed three real defects before merge: (1) CRITICAL —
the engine never called `reset()`, but FluidAudio's `StreamingEouAsrManager` latches `eouDetected =
true` and accumulates tokens across the whole session, so EXACTLY ONE segment fired per session and
the partial grew unbounded; fixed by resetting after every EOU (verified against the source). (2)
CRITICAL — fire-and-forget model teardown raced a Stop→Start `loadModels` and wiped the fresh models;
fixed with a serialized, awaitable teardown chain that `start()` waits on. (3) HIGH — the 213 MB
encoder-weights SHA-256 ran on the MainActor with a full heap load; fixed with `.mappedIfSafe` +
detached hashing. New regression tests cover all three plus the previously-uncovered capture-failure,
model-load-throw, and consume-forwarding branches. Second review pass: zero actionable findings.

OPEN (deferred, non-blocking): (1) wire a real per-segment confidence when FluidAudio surfaces
one for the streaming path (PLAN open-Q1); (2) voice-filter speaker classification on Parakeet
EOU segments once utterance-boundary samples are available; (3) `scripts/verify-primary-scenario.sh`
+ `run-asr-eval.py` Parakeet arm on EN cockpit fixtures before any "Parakeet default" consideration
(Phase 4, not yet done); (4) `.xcstrings` catalog entries for the new Parakeet UI strings are
populated by an Xcode GUI build/export (headless xcodebuild only reformats the catalog), so they
resolve to their English source at runtime until then.

## READ FIRST (2026-06-13)

Testing reoriented per owner: the **simulator is for visual UI review only** (page
screenshots, look for clipping/overlap/wraps), and the **real testing effort is core
function on real audio** (transcription + dispatcher/own-readback/other-aircraft
separation). Landed on `main`:

- **Test-plan split** (PR #5): default `Dspeech.xctestplan` = unit + core UI flows +
  `ScreenshotSmokeTests` page captures; the accessibility / Dynamic-Type / multi-locale
  sweeps moved to `DspeechFull.xctestplan` behind a manual `workflow_dispatch` CI lane
  (`AccessibilityAuditUITests` + secondary voice-filter/translation UI tests deferred while
  core is built). CI `tests` job runs core only.
- **Real-ASR core eval** (PR #5): `scripts/testdata/` — `voice-corpus.json` (controller /
  own-pilot / other-aircraft, multiple call-signs), `generate-voice-corpus.sh` (`say` →
  16kHz mono WAV + ffmpeg VHF-radio degradation + speaker overlap; audio gitignored under
  `tmp/`), `run-asr-eval.py` (runs the REAL WhisperKit/Apple engine, ATC-number-normalized
  WER + classification per clean/radio/overlap). This REPLACES trust in the synthetic
  `dspeech-replay` replay-eval, which scores ground-truth-text-through-a-gate with a fake
  amplitude speaker substitute (meaningless WER 0.000). It surfaced: transcription is good
  (clean WER 0.18, radio 0.21) but classification was wrong (58%) due to a real decode bug.
- **WhisperKit optional locale** (PR #5): nil recognition locale = auto-detect hint, not a
  `recognition-locale-unavailable` failure (the engine was unusable without an Apple
  on-device dictation locale). + DEBUG `-dspeech.e2e.autostart-listening` headless seam.
- **Call-sign decode robust to ASR-fused tokens** (PR #6): `CallSign.phoneticWords` now
  splits at letter↔digit boundaries, so "123ALPHA"/"3ALPHA" mush no longer breaks call-sign
  assembly — a controller clearance to OUR aircraft is no longer wrongly suppressed.
  Verified via the real-engine eval: clean classification **58% → 92%**. ReplayKit's
  `CallSign.swift` is a symlink to `Dspeech/Core/VoiceFilter/CallSign.swift`.

REMAINING: (1) residual ASR mis-hearing "Alpha Bravo" → "ABA" (fuzzy-match, lower ROI);
(2) UI screenshot visual review pending local iOS-26.5 simulator runtime install (Xcode
updated to 26.5 on reboot; `xcodebuild -downloadPlatform iOS`). Pilot-readback filtering
remains ADR-0007 phase-2 (FluidAudio voice model). Owner standing goal: keep developing →
pushing → CI builds → App-Store-shippable; never asked about git/WIP mechanics.

## READ FIRST (2026-06-12)

PR #3 "production-ready" was FALSE-READY: first human use broke the core flow (text
replaced at silence boundaries; filter semantics inverted vs owner intent). Incident +
self-retro: global memory `feedback_primary_scenario_proof`. The binding work now:
`docs/PLAN-2026-06-12.md` → `docs/SPEC-2026-06-12-core-semantics-rebuild.md`
(dispatcher-only durable transmission blocks, real-audio harness on the French ATC
fixtures, WhisperKit phase). Do not trust the previous "ready" claims below.

**Phase A LANDED** (`feat/core-semantics-rebuild` @ `47bc870`, suites green, harness
gate passed, run-note `docs/run-notes/2026-06-12-core-semantics-rebuild-phase-a.md`):
D-1 fixed (interim commit at every task boundary + .taskRestart marker), pure
TransmissionAssembler (gap-glued whole transmissions, overlap-merge), D-2 semantics via
TransmissionClassifier (urgency/callsign/voice/honest-fallback), French phonetics
layer, real-ASR harness `dspeech-replay transcribe` + `scripts/
verify-primary-scenario.sh` (macOS on-device fr-FR; both fixtures = single coherent
DISPLAYED blocks; callsign anchor + filter verified on real audio). Replay-tail: ON
(empirical §2.2, loss > duplication). **Phase B + Stage 3 LANDED** (@ `7aeecbd`, run-note
`docs/run-notes/2026-06-12-core-semantics-rebuild-phase-b-stage3.md`): WhisperKit
harness engine + ADR 0011 (apple default), LiveAudioCaptureConduit extraction,
pinned-revision model installer + Settings engine picker, WhisperKit live engine
(adapter-confined import, local-only load), transmission cards/persistence/filtered
reasons/no-anchor hint in the app, 3 visual defects eye-caught & fixed (hint overlap,
bubble clip, AX-XXXL header overflow). REMAINING: l10n fill for new strings (en-only),
§4.4 BlackHole sim E2E (owner sudo), device latency check for WhisperKit live, owner
hand-test = final gate. mac24 env: fr dictation asset installed; CLI Speech needs
run-loop pumping; whisper model cache ~/.cache/dspeech-whisperkit.

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
  insufficientSpeech fails open everywhere. Segment gate (ATCTranscriptGate.evaluate) is
  locale-aware: it decodes the callsign in the segment's recognition language
  (segment.sourceLanguageCode), so a French clearance read with French digit words
  ("November un deux trois") matches at the segment level — not just the card classifier.
  Behavior-preserving for English (localeIdentifier nil/en → English decode path); adding a
  decode path only ADDS matches, never flips display→suppress, and the only widened tier
  (matchesAbbreviated) is DISPLAY-only, so it can't hide a clearance. The lenient tier already
  matches NATO-letter tails in English; the locale fix matters specifically for numeric-tail
  callsigns, where French digit words decode only under fr-FR.
- **Production-readiness expert audit + fixes (2026-06-15, 5-agent team, all CI-green)**: parallel
  niche audit (Swift-6 concurrency / privacy-security / audio-ASR / a11y-UI / perf-resilience) + 3 fix
  rounds, 12 commits. HIGHs: callsign recognitionTask handler missing @Sendable → off-main EXC_BREAKPOINT
  crash (same banked tap class; sibling engine already @Sendable) FIXED; WhisperKit live resample
  violated the AVAudioConverter contract (fresh converter per buffer + always-.haveData re-feed) FIXED
  via a session-persistent converter + consumed-flag input block (OSAllocatedUnfairLock, FluidAudio
  idiom) + a real-converter host test. MEDIUMs: persistence fsync-on-MainActor → checkpoint-flush (drop
  per-append fsync + .atomic; flush at endSession + the F8 background hook; torn-scratch recovery skip);
  unbounded capture/recognition FIFOs → bufferingNewest + drop counters (no silent truncation); unbounded
  in-memory transcript → 2000-transmission window (silent cap, older→SessionHistory) with segmentOwner-
  gated derived-state eviction + O(visible) render; arbiter preemption now stops the preempted meter;
  5 sub-44pt tap targets → 44pt. LOWs: mode-aware PrivacyBadge, hidden decorative symbols, voiceprint
  .completeFileProtection at write, ModelPackState/store-init silent-swallow logging. OWNER product
  calls: removed the dead unrendered ATCVoiceIndicator render API (kept VoiceFilterDecision.indicator);
  transcript RAM cap 2000 silent. ADR-0002 local-only RE-PROVEN clean (every egress traced; on-device
  SFSpeech forced; manifest correct). DEFERRED (LOW/device, non-blocking): P4 WhisperKit window growth
  (device-only verification), P5 FluidAudio unload-on-disable, P6 VM deinit task-cancel. Process win:
  local `xcodebuild build -destination generic/platform=iOS` is the app-compile gate (caught 3 Swift-6
  errors pre-push) — see [[dspeech-local-app-compile-works]].
- **Crew-voice / dispatcher-separation audit + refactor (2026-06-15)**: 6-dimension audit found a
  hide-a-dispatcher path — the voice-first gate suppressed ANY .pilot before the callsign check, so a
  controller false-accepted as crew without a callsign was hidden by both layers. FIXED:
  ATCTranscriptGateConfig.pilotSuppressThreshold (0.82, above the 0.72 SpeakerMatcher match boundary,
  at the bottom of the measured same-voice range) — gate suppresses crew only at high confidence; the
  [0.72, 0.82) band falls through to the relevance check and fails OPEN. Also: honest calibration
  comment (0.72 came from a SYNTHETIC 12-clip/3-voice corpus that understates the cross-speaker tail);
  removed dead ATCRelevanceDecision.holdContinuation; extracted enum logName (killed stringify dup);
  storage persist/delete failures now logged not swallowed; pinned urgency-when-filter-disabled +
  the removeAllCrewMembers privacy wipe. RESOLVED since: modelPackState vs identifier two-sources-of-
  truth now assert+throw on cold-start disagreement (2966ae0); the real-FluidAudio calibration now has
  a CI regression guard — `scripts/check-speaker-calibration.sh` + the path-filtered `speaker-
  calibration.yml` lane run the REAL WeSpeaker model over the labeled corpus and FAIL if the cosine
  separation stops bracketing the thresholds (validated on the GH runner: SAME min 0.820, CROSS max
  0.599, separable; bounds sameVoiceMinCosine 0.75 / crossVoiceMaxCosine 0.65 in the corpus manifest).
  ADVERSARIAL SELF-REVIEW (2 lenses) found NO dispatcher-hiding/urgency-suppression path — core fix
  holds — and 4 real runtime defects, all FIXED + unit-green: (1) indicator() badged ANY .pilot
  .pilotSuppressed regardless of score, mislabeling an uncertain shown pilot on a visible clearance
  (removed the score-blind early-exit; see [[feedback_enum_payload_silent_drift]]); (2) removeAll-
  CrewMembers early-returned on empty memory, leaking corrupted-on-disk voiceprints — now wipes
  storage unconditionally; (3) a persisted pilotSuppressThreshold <= match boundary collapses the
  fail-open band — loadSnapshot now rejects it as .gateConfigCorrupted; (4) saveGateConfig swallowed
  encode failures + the availability log was redacted — both fixed. Also floored the calibration guard
  against a degenerate corpus (>=3 same/cross pairs + required bounds; see
  [[feedback_vacuous_guard_measure_reach]] recurrence). BACKLOG CLOSED (3 traced items): mixed-band is
  REACHABLE+kept (NOT vestigial — SpeakerMatcher returns .mixed for any best cosine in [0.50, 0.72),
  now pipeline-indicator-tested); enrollment-quality asymmetry is intentional and PINNED (3 tests:
  enrollment ungated by design — the 0.25 floor wrongly rejected a quiet on-device enrollment — while
  matching gates only the incoming candidate and ignores the enrolled profile's quality); FileProtection
  now has a constructor-injected FileManager seam on UserDefaultsVoiceFilterStorage + a .complete spy
  test (reach-floored: asserts setAttributes was called before checking .complete). STILL OPEN:
  N-aware roster threshold (deferred — needs real calibration data, not a synthetic magic number). NEW
  PRODUCT FINDING for Andrei: ATCVoiceIndicator (the per-segment classification badge: pilotSuppressed
  / mixedSpeakerCandidate / probableDispatcher / dispatcherAddressedOwnCallSign / …) is computed in
  VoiceFilterPipeline + stored in LiveTranscriptionViewModel.filterIndicators + exposed via
  indicator(for:), but NO SwiftUI view renders it — the suppression hide/unhide is wired, the WHY-badge
  is UI-dead. Decision: render the badges (give the pilot visibility into the filter's per-segment
  calls) or remove the unused indicator API. The 0.72/0.82 thresholds remain PROVISIONAL until
  re-derived on real device-path audio (the synthetic-corpus guard catches REGRESSION, not the tail).
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
- ADR 0011: Apple default + WhisperKit selectable (multilingual).
- ADR 0012 (2026-06-22, LANDED 2026-06-23 on `feat/parakeet-third-engine`): third ASR engine —
  Parakeet EOU streaming via FluidAudio (English-only, lowest-latency 160ms chunks, true streaming
  + built-in EOU), default policy unchanged. Adapter + engine + pinned-manifest installer (per-file
  SHA-256 verification) + settings wiring + English-only picker exposure all landed; full
  DspeechTests suite green. Phase 4 harness arm (EN cockpit fixtures) + real-confidence wiring
  deferred (see the 2026-06-23 READ FIRST block). Spec at
  `docs/PLAN-2026-06-22-parakeet-third-engine.md`.
- Spec D1-D5 (docs/SPEC-2026-06-11-production-readiness.md) bind all remediation work.

## In flight (wave 4) + open tail

- W10: ContentView decomposition DONE (946→730; banners + DEBUG scripted engine extracted to
  TranscriptBanners.swift / RenderStableScriptedLiveTranscriptionEngine.swift, behavior-preserving).
  Open: iPad adaptivity, full l10n fill, privacy-toggle truthfulness. W11: scripted-engine seam,
  real-pipeline replay eval; PBT sweep for the voice-filter safety core DONE — all three components:
  CallSignPropertyTests + ATCTranscriptGatePropertyTests + TransmissionClassifierPropertyTests
  (seeded-PRNG, reach-counter-gated against vacuity, shared generators in PropertyTestSupport). Gate
  pins urgency-never-suppressed + fail-open + pilot-suppress + addressed-iff-display + continuation/
  other-callsign; classifier pins the content-first divergence (own callsign shown even from pilot
  voice, where the gate suppresses). PBT also covers the ASR assembly core
  (SpeechActivitySegmenterPropertyTests: continuous-speech-always-cuts anti-dictaphone +
  boundary-never-cuts-on-silence anti-churn; TransmissionAssemblerPropertyTests: endedAt>=startedAt
  under backwards timestamps + unchanged-partials-don't-outlast-gap + gap-split + replay-tail dedup).
  No timing-window assertions. W12: warnings-as-errors DONE
  (SWIFT/GCC_TREAT_WARNINGS_AS_ERRORS=YES both configs); version xcconfig, script robustness,
  staged-only gitleaks hook, SHA-pinned actions remain.
- After wave 4: ko locale + listing-it/uk + release-policy locale check; final adversarial
  re-review cycles; device-verification lane remains the honest gap (run-on-device
  checklist: lock/call/cable-pull scenarios per ADR 0010) until a physical device session.
- Known accepted-for-now: replay-tail may rarely duplicate a word across task restarts
  (loss is worse than duplication for ATC) — quantify on the device replay corpus.
- BUILD GOTCHA: after editing a file already in the test bundle, `xcodebuild build test` can run a
  STALE bundle (recompiles the file but doesn't relink the new code into the run) — the tell is an
  unchanged test COUNT or an identical pass/fail set. A `-only-testing:<Suite>` run forces a proper
  relink; re-run the full suite after and verify the expected test count (e.g. 735) before trusting
  green. Bit twice in the PBT work (new gate suite not registering; a fixed generator not taking).
- PBT convention: a shared generator's full output range must satisfy EVERY consumer's preconditions.
  randomTranscript returning "" tripped the classifier's first-priority insufficientEvidence guard
  (the gate has no empty guard, so it passed there) — shared generators are non-empty; empty/junk get
  their own explicit fixtures. Each guard-bearing property carries an exercised-counter reach gate.
- CI flake fixed at root: CallsignDictationServiceTests.wait(for:) used a 5s poll that timed out on
  the CPU-starved hosted runner before the async append Task was scheduled (passed locally) — bumped
  to 60s (returns as soon as the condition holds, so headroom only costs wall time on real failure).
  This was the hosted "Unit tests (DspeechTests)" red; distinct from the documented hosted-UITest
  CPU-starvation flakes. Adversarial review of the segmenter/assembler PBT then found + closed 5
  stateful/edge coverage gaps (see [[feedback_pbt_branch_coverage]]).
