# ADR 0010 — Live-session survival: keep-awake, no background audio mode

Date: 2026-06-11. Status: accepted.

## Context

The 2026-06-11 ultra-review confirmed the worst product defect class: a live cockpit
session silently dying mid-flight. Causes: screen auto-lock (no idle-timer policy +
F8 stops capture on backgrounding), audio interruptions with no auto-resume, engine
configuration changes with no rebuild, and a dead engine left showing "Listening".

## Decision

1. **Keep-awake while listening** (`isIdleTimerDisabled` bound to the live session and
   scene phase) — the screen never auto-locks mid-session; the transcript stays glanceable
   (cockpit use is a powered, mounted device — battery is the pilot's call).
2. **Auto-resume after interruptions** when iOS signals `.shouldResume` (a phone call must
   not end transcription); engine-configuration changes rebuild in place; every
   unrecoverable path surfaces a visible failure — never a zombie "Listening".
3. **NO `UIBackgroundModes: audio`** this iteration. F8's deliberate stop-on-background
   stays: receive-only product, no covert capture, no App-Review exposure for background
   recording, and the keep-awake policy removes the main reason a session would background
   itself. The transcript persistence layer (D4) bounds the cost of any remaining stop.

## Option recorded for Andrei (explicit sign-off required)

Background-audio capture (screen lockable, capture continues) is feasible and arguably
matches real cockpit use (device pocketed during high workload). It requires: the
`audio` background mode, App Review justification for continuous background mic use, an
always-visible recording indicator story, and an ADR superseding F8 + this one. Not
implemented; do not add the entitlement without that ADR.

## Consequences

- "The screen is the session" — UI communicates that locking/leaving stops capture
  (stop-on-background notice), and history preserves everything already transcribed.
- The device-verification lane must include: lock attempt during session (screen stays
  awake), incoming call mid-session (auto-resume), cable pull (route-loss stop + notice).
