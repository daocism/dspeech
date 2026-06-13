# 2026-06-12 — Core-semantics rebuild, Phase B + Stage 3 (spec §5, §6, §4.4 partial)

Continues `2026-06-12-core-semantics-rebuild-phase-a.md`. Branch
`feat/core-semantics-rebuild`. Same execution model (Claude architect/reviewer,
Codex workers W5-W8 in worktrees, every diff Claude-reviewed before cherry-pick).

## Phase B landed

- **B1 harness engine** (`31e9332`): `--engine whisperkit` in `dspeech-replay
  transcribe` — argmax-oss-swift pinned `exact: 1.0.0`, large-v3-v20240930_626MB,
  fr decode with word timestamps into the same assembler+classifier. Apple runner
  moved to real-time async pacing (unpaced feed outran the recognizer: simulated
  restarts killed the task pre-result; benign 1110 now recycles the task mid-feed
  exactly like the live engine).
- **ADR 0011** (`7aaee40`): two-engine strategy, Apple stays live default
  (streaming partials + contextualStrings biasing + no hallucination), WhisperKit
  selectable (better callsign capture on fixtures: caught «Fox Golf Oscar» where
  Apple missed «Fox»; hallucination risk: «descente»→«décembre»). Comparison table
  in the ADR.
- **W5 capture conduit** (`866dc14`): `LiveAudioCaptureConduit` extracts the
  crash-hardened capture path (tap `format:nil`, `@Sendable` deep-copy, arbiter,
  session discipline, config-change rebuild) — Apple engine refactored onto it,
  lifecycle tests passed UNCHANGED.
- **W7 model installer + picker** (`5117172`): `WhisperKitModelInstaller` mirrors
  the voice-pack pattern — HF revision PINNED to `97a5bf9bbc…` (verified == repo
  main at build time), 17 expected files byte-size-verified against the real model,
  per-file SHA256 manifest, disk-full taxonomy, delete; engine picker in Settings
  (default apple), honest fallback hint when model absent. Engine-corrupted storage
  issue got its own label (`910c674`).
- **W6 live engine** (`ef9637c`): `WhisperKitLiveTranscriptionEngine` on the
  conduit — 16kHz resample, rolling window, 1s partial decode cadence,
  silence/28s-cap finalize, `import WhisperKit` confined to the adapter actor,
  local-only model load (`download:false`), ContentView factory with logged Apple
  fallback. SPM package wired exact 1.0.0 (FluidAudio pattern).

## Stage 3 landed (W8: `cd33651`, `7a3df8d`, `d350760`)

- Assembler classify closure now receives `endedAt` (clock-box hack deleted).
- VM owns assembler+classifier: transmissions are primary state
  (`displayedTransmissions`/`filteredTransmissions`, upsert + list movement on
  classification upgrade), 0.5s tick closes gaps without waiting for events,
  one-time no-anchor hint (persisted once-ever), engine events mapped
  (.partial/.segment/.taskRestart/finish).
- Cards: main list = dispatcher transmissions only, permanent, newest at bottom;
  reason badge per card; LIVE card finalizes into the transmission card; filtered
  pill + review sheet read per-transmission reasons.
- Persistence §6.4: `transmissions.jsonl` per session (closed lines) +
  `open-transmission.json` atomic rewrite per update (crash-loss ≤ last fragment),
  recovery dedupes by id; history/export prefer transmissions, legacy sessions
  pinned backward-compatible.

## Visual sweep (my own eyes, full-frame rule) — 3 defects found & fixed

Simulator iPhone 17 Pro, scripted engine, en/fr × default/AX-XXXL. Evidence in
`img-2026-06-12/`.

1. No-anchor hint OVERLAPPED the first transmission card and truncated mid-word
   («Tap the microp…») → bottom-anchored above the controls + line cap removed.
2. Hint bubble background clipped to 2 lines while text drew 4 (both-axes
   `fixedSize` vs wrapped text) → vertical-only fixedSize.
3. PRE-EXISTING AX-XXXL overflow: both-axes `fixedSize` on the LOCAL/MIC chip row
   made the header column incompressible — history/settings AND the primary mic
   button rendered half off the right screen edge; pure compression then ellipsized
   MIC to «M…» → ViewThatFits: chips side-by-side when they fit, stacked vertically
   at accessibility sizes; FloatingStartControls hardened the same way
   (hint above button when the row doesn't fit).

Verified states: demo/idle, live partial → permanent card (en+fr), no-anchor hint,
filtered pill, review sheet (reason «Addressed to other aircraft»), Settings engine
picker, AX-XXXL header/cards/buttons. All clean post-fix.

## Honest gaps / open tail

- New UI strings are en-only so far (fr falls back to en for the hint, reason
  badges, engine section) — the l10n fill + release-policy locale check remains the
  known open tail from the production-readiness wave.
- §4.4 simulator E2E with REAL audio into the sim mic needs BlackHole
  (`brew install blackhole-2ch`, owner sudo) — not yet installed; the macOS CLI
  harness remains the ASR-truth gate (Apple on-device SFSpeech does not run in the
  iOS Simulator at all).
- WhisperKit live-engine latency on REAL iPhone hardware unmeasured (sim is
  CPU-only); default stays Apple per ADR 0011 until a device session.
- Engine choice takes effect on next session construction (app relaunch or
  re-entering the main scene), not mid-session.
- Owner hand-test on the physical iPhone is the FINAL acceptance gate (§7.5) —
  explicitly invited, never claimed.
