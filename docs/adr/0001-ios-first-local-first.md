# ADR 0001: iOS-first and local-first MVP

## Status

Accepted for prototype.

## Context

Dispeech targets cockpit/ATC comprehension. Audio may include sensitive route, pilot, or operational data. Connectivity in flight can be unreliable. The first market/test group is expected to have iPhone/iPad hardware.

## Decision

Build a native iOS prototype first. Treat offline/local transcription as the default product behavior. Cloud ASR/translation can exist later as an explicit fallback, never as the hidden default.

## Consequences

- We optimize for Apple frameworks, Core ML/Neural Engine, and USB-C audio behavior first.
- We need a replayable audio corpus early to avoid subjective ASR choices.
- Android is intentionally deferred until iOS audio + ASR proof exists.
