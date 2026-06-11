# Dspeech Production-Readiness Spec — 2026-06-11

Source: 64-agent ultra-review (12 code dimensions + 3 research tracks + adversarial
verification). 163 confirmed findings + 7 completeness-critic findings. Raw inventory:
`tmp/review-findings.json`, research: `tmp/review-research.json` (untracked working files).
Baseline at branch point: full suite green, zero warnings, simulator iPhone 17 Pro / iOS 26.4.

Goal: 100% production-ready. A pilot can fly with this app; an expert auditor finds nothing
to flag. Every WP has acceptance criteria; nothing ships without them met.

## Strategic decisions (bind all WPs)

- **D1 — Speech stack stays SFSpeechRecognizer for this iteration.** Research verdict:
  `SpeechTranscriber` (iOS 26) does NOT honor contextual-string biasing; callsign/ATC-vocab
  biasing is a hard product requirement. `DictationTranscriber` DOES honor it and is the
  modern migration target — but the migration is its own slice with its own device-eval.
  Action now: ADR 0009 records this; the locale-capability source (currently
  SpeechTranscriber-based) must be re-aligned to the engine actually used (WP7).
- **D2 — Session survival = keep-awake, not background audio.** `isIdleTimerDisabled`
  while listening solves auto-lock death without App-Review-sensitive background recording.
  `UIBackgroundModes: audio` is a product decision for Andrei → documented as an option in
  ADR 0010, NOT implemented.
- **D3 — The voice filter must be fail-safe in the safety sense:** any doubt → show the
  segment. Urgency traffic (MAYDAY/PAN PAN/SECURITE/"all stations") is NEVER suppressed.
  Suppression is always visible and reviewable.
- **D4 — Transcript is flight data.** It persists by default, survives kill/jetsam/crash,
  and is exportable. Losing a transcript is data loss (severity: critical).
- **D5 — No suppression-style fixes.** Warnings-as-errors goes on and stays on; every gate
  failure is root-caused (global rule zero-warnings-real-fixes).

## Work packages

### P0 — flight-critical

**WP1 — Live session survival** (owner files: `Core/ASR/AppleSpeechLiveTranscriptionEngine.swift`,
`App/CaptureCoordinator.swift`, `App/RouteHealthMonitor.swift`, `Core/Audio/LiveAudioSessionRouting.swift`)
- Handle `AVAudioEngineConfigurationChange` (rebuild tap/engine or fail loudly; never zombie `.listening`).
- `restartRecognition` on a dead engine → surface `.failed` (today: silent no-op, status stays listening).
- Missed `interruptionEnded` must not latch `blocksStart` forever; foreground re-entry refreshes route health.
- Fix one-shot `AsyncStream` re-subscription bug (route observation dead after `fullScreenCover` cycle; also RouteHealthMonitor double-consumer).
- `mediaServicesWereReset` → full engine/session rebuild path.
- Interruption end with `.shouldResume` → auto-resume capture (pilot does not re-tap after a call).
- Acceptance: unit tests for every transition (config-change, dead-engine restart, latch,
  resume); no path leaves UI "Listening" with a dead pipeline.

**WP2 — Audio session correctness** (owner files: engine `beginAudioSession`,
`Core/ASR/CallsignDictationService.swift`, `Core/ASR/VoiceEnrollmentRecorder.swift`,
`App/AudioSourceController.swift`, level meter)
- Remove documented-invalid combos: `.duckOthers` with `.record` (3 sites); `.notifyOthersOnDeactivation` on activation.
- BT consistency: routing layer advertises HFP inputs → capture session must activate with the matching options (`.allowBluetoothHFP`), or routing must not advertise them.
- Single-capture arbitration: dictation/enrollment must not stomp or deactivate the session under live capture (explicit owner token).
- Level meter: correct interleaved windowing + multi-channel mixdown consistent with ASR mono path.
- Acceptance: documented-valid option sets per Apple docs; arbitration unit tests; meter math tests.

**WP3 — Voice-filter safety** (owner files: `Core/VoiceFilter/CallSign.swift`,
`ATCTranscriptGate.swift`, phonetic parser, gate config)
- Urgency bypass: MAYDAY / PAN PAN / SECURITE / "all stations" → never suppressed, ever.
- Abbreviated-callsign matching (ICAO last-3 / type+last-3 conventions) so own calls are never hidden.
- Add missing phonetic variants the app itself biases toward: X-ray, Juliett/Juliet, Alfa/Alpha, Whisky/Whiskey, Tree, Fife, Fower, Niner.
- Stop-committed partials must pass through the gate policy (no-discard-on-Stop invariant).
- Disabling the filter un-hides previously suppressed segments.
- Fix fail-direction inconsistency (post-ASR `.insufficientSpeech` suppress vs pre-ASR fail-open) → fail-open both.
- Acceptance: property-based tests over callsign grammar (registration ↔ spoken forms); urgency corpus test; zero suppressed-urgency cases.

### P1 — data integrity + core UX

**WP4 — Transcript persistence + history + export** (new `Core/Persistence/`,
`App/LiveTranscriptionViewModel.swift`, new history view)
- Session-scoped store (JSONL or Codable file per session, `FileProtectionType.completeUntilFirstUserAuthentication`, excluded-from-backup OFF — it is user data).
- Autosave on every final segment; restore-last-session affordance after relaunch.
- Session history list + share/export (plain text + file).
- Bound in-memory growth for 4-hour sessions (windowed rendering; full data on disk).
- Acceptance: kill -9 mid-session loses ≤ the in-flight partial; round-trip tests; 10k-segment scroll stays fluid.

**WP5 — Cockpit UX correctness** (owner file: `App/ContentView.swift` + extracted views)
- `UIApplication.shared.isIdleTimerDisabled = true` while listening (cleared on stop/background) — with WP1 this closes the screen-lock death.
- Auto-scroll/bottom-anchor transcript with manual-scroll override + "jump to live" affordance.
- Clear → confirmation; with WP4, cleared sessions remain in history (undo path).
- Suppressed-segment review surface: render `ATCVoiceIndicator`, "N suppressed" pill → review sheet.
- Translation failures visible on main surface (not buried in Settings); permission-denied banner gets "Open Settings" action.
- Demo transcript: persist `hasEverStarted` (first-run only, never on cold relaunch).
- Acceptance: a11y audit matrix green incl. AX-XXXL × longest locale; UI tests for auto-scroll, clear-confirm, review sheet.

**WP6 — Observability** (cross-cutting, additive only)
- `os.Logger` per subsystem (engine, audio-session, routing, filter, persistence, translation) with privacy-correct interpolation; log every lifecycle transition + failure with context.
- Acceptance: a field failure (engine death, route loss, install failure) is reconstructable from `log collect` output alone.

### P2 — robustness

**WP7 — ASR engine robustness**: termination taxonomy beyond code 1110 (203/'Retry',
duration-limit → restart; document constants), replay tail buffers across task restarts,
recognizer availability re-check via delegate/KVO not one-shot init read, kill the 0.5
confidence fabrication (0 stays 0, UI shows VERIFY not "50%"), seed contextualStrings with
spoken/phonetic callsign form, dictation service gets ICAO contextualStrings + configured
locale, fail-open (not stall) on empty-sample windows, `Locale.Language.languageCode`
instead of `prefix(2)`, align capability-locale source with the engine (D1).

**WP8 — Voice data protection**: voiceprint embeddings → Keychain (or
file-protected store) + backup exclusion + erasure UI (delete pack deletes profiles);
model-pack download pinned to immutable revision matching the byte checksums; relative
container paths; disk-full preflight + honest error taxonomy (no "check your network" for
disk errors); enrollment minimum-duration + voicing gate (real VAD metric, not RMS).

**WP9 — Settings/domain integrity**: privacy-toggle/filter-toggle contradiction resolved;
capable-set narrowing must not permanently overwrite stored locale; default translation
target ≠ default source trap fixed; persistence write failures surfaced (no `try?` drops);
Codable decodes route through validating initializers (parse-don't-validate); foreground
refresh of capable/needs-download state; `PreferredInputResolver` port-type fallback
actually applied to the session.

**WP10 — Concurrency hygiene**: capture→ASR consumer off MainActor with bounded buffering
(+ drop policy that fails loudly); `events()` single-subscriber contract enforced (assert or
multicast); audio-session (de)activation off main; `RegistryBaseURLGate` cancellation-aware;
every `@unchecked Sendable` justified or replaced; ContentView init side effects → explicit
construction; ordered event hop (no partial-after-final).

### P3 — platform, tests, release

**WP11 — iPad + layout + decomposition**: ContentView.swift (1553 lines) split into
≤400-line feature files; size-class-adaptive layout; iPhone-hardcoded copy fixed; iPad in CI
matrix + a11y sweep; uncataloged strings into `Localizable.xcstrings`; 44pt targets;
VoiceOver-coherent transcript cards; onboarding scroll fallback at AX sizes.

**WP12 — Test honesty**: launch-arg scripted-engine seam → UITest drives real transcript UI
(cards, VERIFY, gloss, clear, review); `AppleTranslationService` integration test;
engine-callback mapping tests; PBT for `CallSign.matches`/`PhoneticCallsignParser` +
segmenter; replay-eval CI gate runs the REAL `VoiceFilterPipeline` (not synthetic
classifier); no real network in UI tests (local fixture registry); timing-window assertions
replaced; `try!`→`#require`; device lane: scripted `run-on-device` checklist becomes an
executable XCTest plan run whenever a device is attached, and release gate records it.

**WP13 — Build/CI/release**: `SWIFT_TREAT_WARNINGS_AS_ERRORS`/`-warnings-as-errors` on;
version strategy (single source, agvtool or xcconfig); scripts: `set -euo pipefail` fixes,
tmp/ mkdir, unreachable diagnostics fixed, flake-report no longer self-neutralizes; xcresult
upload on CI failure; actions SHA-pinned; gitignore: un-shadow fixture audio dirs, add
`*.xcresult`; remove dead env var; screenshot gate freshness check; branch-protection note
for Andrei (GitHub settings — needs owner).

**WP14 — Decisions + docs + store consistency**: ADR 0009 (speech stack, D1), ADR 0010
(session survival policy, D2; background-audio option for Andrei), privacy manifest
completeness (FluidAudio dep manifest story), store-listing locale set ⊆ app locale set
(+ release-policy check), refresh `.ai/project-state.md` + `docs/ai-kb/current-context.md`
to HEAD truth.

## Execution model

Claude = architect/reviewer/integrator; Codex GPT-5.5 workers implement WPs in parallel
waves with disjoint file ownership. Every diff: Claude review → full simulator suite green →
atomic conventional commit. Wave order: (1) WP1+WP2+WP3, (2) WP4+WP5+WP6, (3) WP7-WP10,
(4) WP11-WP14, then adversarial re-review cycles to zero findings. Device-only items are
implemented + scripted now, exercised on hardware when a device is attached (gap recorded
honestly in the release gate).
