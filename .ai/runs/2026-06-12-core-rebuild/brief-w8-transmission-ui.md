# W8 — Stage 3: transmission semantics in the app (VM wiring + cards + persistence)

Read brief-common.md, docs/SPEC-2026-06-12-core-semantics-rebuild.md §6 (BINDING — this
is the D-2 fix the owner described), docs/PLAN-2026-06-12.md "Owner intent", then the
landed core: TransmissionAssembler, TransmissionClassifier, Transmission model,
LiveTranscriptionViewModel, ContentView, TranscriptCardViews, TranscriptStore.

## Files you own

- `Dspeech/Core/ASR/TransmissionAssembler.swift` (ONE signature change, see below)
- `DspeechTests/TransmissionAssemblerTests.swift` (update for the signature)
- `Dspeech/Tools/ReplayKit/Sources/DspeechReplayKit/TranscribeCommand.swift` +
  `WhisperKitTranscribe.swift` (mechanical: replace the TransmissionClassifierClock
  currentTime plumbing with the new closure param; delete the clock box; verify with
  `cd Dspeech/Tools/ReplayKit && swift build` and one transcribe run per engine)
- `Dspeech/App/LiveTranscriptionViewModel.swift`
- `Dspeech/App/ContentView.swift`, `Dspeech/App/TranscriptCardViews.swift`
- `Dspeech/Core/Persistence/TranscriptStore.swift`
- `DspeechTests/LiveTranscriptionViewModelTests.swift`, `DspeechTests/TranscriptStoreTests.swift`
- `Dspeech/Localizable.xcstrings` (new keys, en source values)
- `DspeechUITests/DspeechUITests.swift` (update scripted-engine smoke for the new card
  semantics if its assertions break; keep assertions meaningful, never weaken)

No new files → no pbxproj changes.

## 1. Assembler classify signature (kills the clock-box hack)

`classify: (_ text: String, _ speakers: [SpeakerMatchDecision], _ endedAt: Date) ->
TransmissionClassification` — assembler passes the open transmission's current
endedAt. Update tests + both harness call sites (TransmissionClassifier.classify
already takes endedAt).

## 2. ViewModel: transmissions become the primary state (spec §6.1/§6.2)

- VM owns a TransmissionAssembler + TransmissionClassifier, constructed with the
  configured callsign (locale-aware) + voicePackActive from the existing
  VoiceFilterPipeline capability, gap from a new Settings-tunable value (default 3.5,
  range 2-6 — add `transmissionGapSeconds` to RecognitionSettings following its
  existing persisted-property pattern; Settings UI slider/stepper is OPTIONAL this
  pass, the stored default is what matters).
- Event mapping (in startObservingEvents): `.partial` → process(.partial(text, at:
  now)) AND keep partialText for the LIVE card; `.segment` → process(.fragment(
  segment:, speaker: nil, at: now)); `.taskRestart` → process(.taskRestart(at: now));
  status .stopped/.failed → finish(at: now). `now` = Date() at event receipt (wall
  clock; injectable `now: () -> Date` for tests).
- A repeating MainActor task (0.5s) while listening calls tick(now:) — gap closes
  must not wait for the next event. Cancel it on stop/failed.
- State: `private(set) var displayedTransmissions: [Transmission]` (classification
  .displayed, open one included and replaced in place on .updated),
  `filteredTransmissions: [Transmission]`, plus
  `var oneTimeNoAnchorHintVisible: Bool` — true the first time a transmission
  classifies .displayed(.noAnchorConfigured) in a session AND no callsign is
  configured; dismissible; persisted once-ever via UserDefaults-backed storage
  (follow FirstSessionStateStorage pattern).
- A transmission moving between displayed/filtered on classification upgrade must
  move lists (remove from one, append/update in the other) — pin with a test
  (callsign arrives at word 6 → block moves from filtered to displayed).
- Keep `segments`/existing API intact for history/suppressed-review surfaces that
  still consume segments — existing tests must stay green except ones whose
  semantics §6 genuinely changes (justify each in the commit body).
- Demo content: untouched (TranscriptDemoViewModel path).

## 3. Cards (spec §6.1 — the existing card design IS the target look)

- Main list shows ONLY `displayedTransmissions`, newest at bottom, each a permanent
  card: TranscriptCardViews gets a Transmission-based card variant (reuse the exact
  existing card styling/badges; show transmission text + time range + classification
  reason badge where the segment card showed its metadata). Cards never disappear or
  get rewritten after close (`.closed` is immutable).
- The LIVE in-progress card keeps rendering `partialText` exactly as today and
  finalizes INTO the transmission card (when the open transmission updates, the live
  card shows only the not-yet-fragmented partial).
- Filtered pill + review sheet: switch their data source to
  `filteredTransmissions` with per-transmission reason text (localized strings per
  TransmissionFilterReason case). Urgency rows can never appear here by
  construction (classifier guarantees) — do not add UI for it.
- Accessibility identifiers: `transmission-card`, `transmission-reason-badge`,
  `filtered-transmissions-pill`, `no-anchor-hint` (+ keep existing ids working).
- Badges/chips: lineLimit(1) + minimumScaleFactor per the repo's badge rules; the
  hint renders as a floating overlay at intrinsic size, NEVER inline in a contested
  row (hard rule from the 2026-06-11 visual-review incident).

## 4. Persistence per transmission (spec §6.4)

Extend TranscriptStoring + FileTranscriptStore:
- `func append(_ transmission: Transmission, to sessionID: UUID) throws` — one JSONL
  line per CLOSED transmission in a new `transmissions.jsonl` per session dir
  (same flush discipline as segments).
- Open-transmission durability: on every `.updated`, write/rewrite a single
  `open-transmission.json` (atomic replace); delete it when the transmission closes
  (its closed line subsumes it). Crash-loss bound = the open transmission's last
  fragment, matching spec.
- `func transmissions(in sessionID: UUID) throws -> [Transmission]` — closed lines
  plus, if present, the orphaned open-transmission.json recovered AS closed (crash
  recovery), deduped by id.
- `exportText(for:)` and SessionHistoryView: prefer transmissions when the file
  exists; legacy segment-only sessions keep working (backward compat — pin with a
  test).
- VM persists via these APIs from the update stream (closed → append; updated →
  rewrite open).

## 5. Verification (definition of done)

- Full xcodebuild build test green, zero warnings.
- `bash scripts/verify-primary-scenario.sh` still green (both engines).
- `cd Dspeech/Tools/ReplayKit && swift run --quiet dspeech-replay transcribe --audio
  ../../../DspeechTests/Fixtures/ATC/atc-2551.wav --locale fr-FR --emit-partials off
  --simulate-restart 4.0` output unchanged in shape (blocks print).
- New VM tests: event mapping, tick-driven gap close, list movement on upgrade,
  one-time hint, persistence calls (fake store), stop finalizes open transmission.
- Commit per concept (assembler signature; VM+persistence; cards) — 3 commits.
