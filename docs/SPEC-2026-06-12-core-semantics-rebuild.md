# SPEC 2026-06-12 — Core-semantics rebuild: dispatcher-only durable transmissions

Binding. Owner-approved intent: see PLAN-2026-06-12. Supplements (does not void) the
2026-06-11 spec's hardening; where they conflict, THIS spec wins.

## §1 Definitions

- **Transmission** — one continuous radio message by one speaker, possibly containing
  short pauses. The unit the pilot thinks in, the unit the UI shows.
- **Dispatcher transmission** — a transmission classified as ATC-addressed-to-us:
  contains the own callsign (full or ICAO-abbreviated, any supported phonetic rendering)
  OR is spoken by a non-pilot voice (when a voice pack + enrollment are active) OR
  contains urgency phrases (MAYDAY/PAN PAN/SECURITE/ALL STATIONS — always shown, never
  filterable).

## §2 Engine continuity (fixes D-1) — files: AppleSpeechLiveTranscriptionEngine + VM

2.1 At EVERY recognition-task boundary (benign 1110 restart, retry/timeout restart,
configuration-change rebuild, availability blip), the current non-empty partial is
COMMITTED downstream as an interim segment (flag `interimRestartCommit`, analogous to the
Stop placeholder) before the new task starts. Text on screen may only ever GROW within a
transmission. A later real final for the same audio MERGES (see §3.3) instead of
duplicating.

2.2 Replay-tail policy is decided EMPIRICALLY on the harness: run fixtures with tail
replay on vs off; keep whichever produces cleaner blocks (duplication vs onset loss),
document the choice in the run-note. The assembler's overlap-merge (§3.3) must make
either choice safe.

2.3 No event path may clear or replace previously displayed transmission text. Pin with
an engine-level test: scripted finals/partials/restarts sequence → concatenated text is
monotonically non-decreasing.

## §3 TransmissionAssembler (new, pure, fully unit-tested) — Core/ASR/

3.1 Input: the engine event stream (partials, finals, interim commits, restart markers,
per-window speaker decisions when available). Output: `Transmission` values
(id, startedAt, endedAt, text, segments, classification, locale).

3.2 Boundary rules: a transmission OPENS at first speech evidence; STAYS OPEN across
silence gaps < `transmissionGapSeconds` (default 3.5, Settings-tunable 2-6) and across
task restarts; CLOSES on gap ≥ threshold, on speaker-change evidence (diarization on), or
on session stop. The fixed ~1s utterance windows / task finals are INTERNAL fragments —
never UI units.

3.3 Merge: consecutive fragments join with a space; if the new fragment's prefix overlaps
the previous fragment's suffix (case/punctuation-insensitive, ≥2 words), the overlap is
collapsed once (handles tail replay and restart double-transcription).

3.4 Classification runs on the WHOLE transmission text (callsign anywhere within it
anchors the entire block) plus voice evidence aggregated over its windows. Re-render when
classification upgrades mid-transmission (e.g. callsign arrives in word 6).

## §4 Harness — the mechanical definition-of-done gate (build FIRST)

4.1 Extend the macOS CLI `Dspeech/Tools/ReplayKit` (sources are symlinks to app code —
real pipeline by construction): `dspeech-replay transcribe --audio <wav> --locale fr-FR
--engine apple|whisperkit [--gap 3.5] [--callsign FOO]` → runs REAL ASR (macOS on-device
SFSpeechRecognizer supports fr; WhisperKit runs on macOS) → REAL assembler + gate →
prints blocks exactly as the UI would group them:

    [DISPLAYED 00:00.4-00:07.9] «...full transmission text...»  (reason: callsign)
    [FILTERED  00:08.2-00:09.0] «...»                            (reason: pilot-voice)

4.2 Fixtures: `DspeechTests/Fixtures/ATC/atc-2549.wav`, `atc-2551.wav` (French ATC,
owner-provided). Acceptance: each fixture's dispatcher speech comes out as WHOLE
coherent block(s), nothing replaced/lost, fragments glued, filtering plausible. Claude
reads the output personally every iteration; the final report quotes it.

4.3 `scripts/verify-primary-scenario.sh` wraps 4.1 over all fixtures for both engines;
it is part of definition-of-done and runs in the local gate (NOT hosted CI — macOS
runner minutes; CI keeps the existing synthetic replay-eval).

4.4 Simulator E2E (after §5): app on iPhone simulator with WhisperKit engine, fixture
played into the sim microphone via BlackHole loopback (owner installs the driver when
asked), driven + screenshotted via XcodeBuildMCP; Claude eye-reviews frames (full-frame
rule). Apple-engine note: on-device SFSpeech does NOT run in the iOS Simulator — that is
exactly why the macOS CLI is the ASR-truth harness for the Apple path.

## §5 ASR engines

5.1 Phase A keeps SFSpeechRecognizer, fixed per §2 (fr-FR locale verified on macOS +
device asset flow unchanged).

5.2 Phase B adds **WhisperKit** (github.com/argmaxinc/WhisperKit, MIT, Swift+CoreML,
multilingual incl. fr, runs on iPhone/iPad AND Simulator) as a second
`LiveTranscriptionEngine`: streaming transcription adapter; in-app model download/manage
UX following the existing voice-pack acquisition patterns (size/progress/delete; local
only after download; pinned model revision + checksum per the supply-chain rules); engine
picker in Settings (default stays Apple until harness comparison says otherwise).
Verify every WhisperKit API against current docs (context7 / repo README) — no
from-memory coding. Rejected alternatives (record in ADR): whisper.cpp (C++ bridging,
no Swift streaming API), sherpa-onnx (heavier integration); revisit only if WhisperKit
fails the harness.

5.3 ADR 0011 records the engine strategy + the empirical fixture comparison table.

## §6 Filter & UI semantics (fixes D-2)

6.1 Main screen shows ONLY dispatcher transmissions (per §1), newest at bottom, each a
permanent card (existing card design IS the target look). Cards never disappear or get
rewritten after close; partial-in-progress renders in the existing LIVE card and
finalizes INTO the transmission card.

6.2 Everything else goes to the filtered list (existing pill + review sheet stay; reasons
now per-transmission). Urgency always displays. With NO callsign configured and NO voice
pack: nothing can anchor dispatcher-ness — show all transmissions as blocks (honest
fallback) with a one-time hint to set the callsign.

6.3 French phonetics: digit words (zéro un deux trois quatre cinq six sept huit neuf,
plus "unité" variant), decimal "décimale/virgule" — extend the parser tables with a
locale-aware layer; ICAO letter words are already international. Property tests mirror
the English ones.

6.4 Persistence: store per TRANSMISSION (one JSONL line per closed transmission;
interim updates rewrite only the open transmission via the existing placeholder-merge
read trick or an explicit revision line — keep the crash-loss bound ≤ the open
transmission's last fragment). History/export show transmissions.

## §7 Acceptance (all required before any ready-claim)

1. `verify-primary-scenario.sh` blocks correct on BOTH fixtures, BOTH engines (Apple via
   macOS CLI; WhisperKit via CLI and Simulator) — output quoted in the report.
2. §2.3 monotonic-text engine test + assembler unit/property tests green.
3. Simulator E2E screenshots eye-reviewed (full-frame rule) across en/fr × default/AX-XL.
4. Full suites green, zero warnings, lint clean, CI green on PR.
5. Run-note with: replay-tail decision, engine comparison, deviations. Owner hand-test is
   the FINAL gate — invite it explicitly, never claim it.
