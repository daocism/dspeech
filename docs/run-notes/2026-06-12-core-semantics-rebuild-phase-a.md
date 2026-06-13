# 2026-06-12 — Core-semantics rebuild, Phase A (spec §2-§4, §6 partial)

Branch `feat/core-semantics-rebuild`, commits `f80000c..47bc870`. Claude = architect/
reviewer/integrator; Codex GPT-5.5 workers W1-W4 in parallel worktrees implemented to
pinned briefs (`.ai/runs/2026-06-12-core-rebuild/`). All worker diffs Claude-reviewed
line-by-line before cherry-pick; full suite green + zero warnings on the integrated
branch; harness gate run personally.

## Landed

- **Contract** (`f80000c`): `Transmission` model + `TransmissionClassification`
  (displayed/filtered + reasons), `TransmissionUpdate`, `TranscriptSegment.
  isInterimRestartCommit`, `LiveTranscriptionEvent.taskRestart`.
- **W1 assembler** (`e3a0a5d`): pure `TransmissionAssembler` (gap 3.5s default 2-6,
  suffix/prefix overlap-merge ≥2 words longest-first, monotonic text, classification
  re-run per text change, restart ≠ boundary). Unit + seeded property tests.
- **W2 engine continuity** (`952f042`) — fixes D-1: pending partial committed as
  `isInterimRestartCommit` segment BEFORE every task boundary (benign restart,
  config-change rebuild, terminal failures incl. availability + loop-guard), then
  `.taskRestart`. `replayTailEnabled` init seam. Monotonic-text lifecycle tests.
- **W4 French + classifier** (`f177161`) — fixes D-2 semantics: fr digit layer
  (zéro…neuf, unité, décimale/virgule ignorable, diacritic-folded) in parser+CallSign
  (locale-gated, en path untouched); `TransmissionClassifier` per spec §1/§3.4/§6.2
  (urgency > callsign > voice-majority > honest no-anchor fallback > addressed-to-other
  > continuation > nonRelevant; empty text fails open).
- **W3+glue harness** (`a4605fd`, `47bc870`) — spec §4.1/§4.3: `dspeech-replay
  transcribe` runs REAL macOS on-device SFSpeechRecognizer with the app's exact request
  config, feeds REAL assembler+classifier, prints event stream + transmission blocks;
  `--simulate-restart` mirrors the app restart path (interim commit + tail re-feed);
  `scripts/verify-primary-scenario.sh` = the local definition-of-done gate.

## Harness evidence (eye-reviewed)

```
[DISPLAYED 00:01.60-00:04.05] «Golf Oscar Armagis sept à la côte»  (reason: noAnchorConfigured)
[DISPLAYED 00:01.10-00:08.27] «Bonjour ton radar, prévois une petite attente secteur alpha écho 1018 avec les voies descente»  (reason: noAnchorConfigured)
--callsign GO    → [DISPLAYED …] (reason: callSignMatch)      ← phonetic "Golf Oscar" anchors
--callsign FBXYZ → [FILTERED  …] (reason: nonRelevant)        ← not ours, filtered
```

Both fixtures assemble into ONE whole coherent block; nothing replaced or lost across a
simulated mid-audio restart (D-1 mechanics reproduced and fixed on real audio).

## Replay-tail decision (spec §2.2) — KEEP ON (default unchanged)

Restart forced at t=4.0 into atc-2551 (worst case: mid-phrase):
- tail ON : interim «…une petite attente» + new task re-hears tail as «Ta tante» →
  ~2 junk words, but keeps «secteur alpha écho 1018…» intact.
- tail OFF: clean continuation but LOSES «secteur» (word clipped at the boundary).
Loss is worse than duplication for ATC ⇒ tail stays ON. Live 1110 restarts fire after
silence (not mid-word), so the garble case is rarer in the field than in this test.
Overlap-merge cannot collapse mangled re-transcriptions (token mismatch) — bounded by
tail length ≤1s.

## Known gaps / notes (non-blocking, tracked for stage 3)

- Assembler classify closure is `(text, speakers)`; continuation-window time is plumbed
  via `TransmissionClassifierClock` in the harness. UI wiring should extend the closure
  signature with `endedAt` instead.
- Speaker-only evidence (empty-text fragment) does not re-classify until next text
  change; irrelevant while no live speaker classifier ships.
- Empty-text closed transmissions are possible (partial-opened, no final) — consumers
  skip them (harness does).
- Block `startedAt` = first partial arrival (feed-time), slightly later than the SEG
  audio start; cosmetic in harness, UI uses wall clock anyway.
- VM still renders segments (incl. interim commits) directly — transmission-card UI
  wiring is stage 3; on-screen duplication at restart boundaries persists until then
  (loss does not).

## Environment

macOS on-device fr-FR asset installed via System Settings → Keyboard → Dictation
languages (+French). CLI Speech requires main-run-loop pumping (semaphore wait starves
callbacks — verified). TCC speech auth granted for this host.
