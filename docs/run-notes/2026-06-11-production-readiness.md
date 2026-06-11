# 2026-06-11 Production readiness

## Mission

Authoritative spec: `docs/SPEC-2026-06-11-production-readiness.md`.

The review found that Dspeech must be treated as cockpit flight data software: a live
session must not look alive after capture has died, and ATC speech must not be hidden
without a visible, reviewable reason. Remediation is running in waves on the production
readiness branch. Claude is the architect, reviewer, and integrator; Codex workers
implement disjoint file sets; the local simulator gate remains the quality bar before
integration.

## Documented deviations

### Audio consumption stays on MainActor for now

The capture tap deep copies recycled AVAudioPCMBuffer values and feeds an unbounded stream
to a lightweight MainActor consumer. This is deliberate for this iteration: dropping
cockpit audio is worse than a transient memory spike, and the consumer work is trivial
routing plus request append. Moving this off MainActor needs a measured bounded buffering
policy that fails visibly when overloaded, not a silent drop path.

### Stop teardown can leave an unverified placeholder

There remains a bounded teardown race where pressing Stop commits the visible partial as
an unverified placeholder, then the recognizer may later emit the real final. The history
layer now persists the placeholder and, when a matching final follows, reads and exports
only the final. If the final never arrives, the placeholder survives in history instead of
the visible line disappearing.

### Pilot voice discard before ASR is disabled

Speaker classification before ASR still runs and logs its decision, but it no longer drops
audio. Suppression is now only allowed after text exists, where urgency traffic and review
surfaces can protect the transcript. Re enabling early pilot discard requires the Phase 2
speaker signal to be plumbed through the text gate and verified on device with real cockpit
audio, including false positive analysis.

## Device verification

The remaining honest gap is physical device evidence. ADR 0010 lists the required scenarios:
screen lock attempt while listening, incoming call with automatic resume, and cable pull
with route loss stop plus notice. Those scenarios must be recorded before any TestFlight
claim that live capture survives real cockpit conditions.
