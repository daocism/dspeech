# ADR 0004: No hardware purchases — wired/cable testing only

## Status

Accepted 2026-05-18. Source: Andrei Notion comment («Делаем пока без покупки, тестить будем на проводе»).

## Context

The audio capture chain is the largest non-software unknown for Dspeech. Various aviation-specific interface boxes were considered (dual-GA-to-USB headset adapters, ATC scanner SDRs, USB-C class-compliant aviation interfaces). All of them introduce procurement, customs, and shelf-life cost. None of them are needed to validate the SwiftUI / ASR pipeline.

## Decision

- No new hardware is purchased in this iteration. No headset adapter, no SDR, no aviation USB-C interface.
- All audio testing uses existing wired/cable paths: built-in iPhone/iPad mic + Lightning/USB-C wired headsets + pre-recorded replay files.
- Bluetooth/wireless audio capture is out of scope until the wired path is validated end-to-end (codec latency and packet-loss behavior are not worth chasing yet).
- The decision to revisit hardware procurement is reopened only after we have a measurable ASR baseline on the cable path AND a concrete deficit we can attribute to the capture chain — not before.

## Consequences

- Replay-file ingestion (drop a recorded `.wav` / `.m4a` into the app, run it through the same pipeline as a live mic stream) is prioritized over live-capture spikes because it makes ASR benchmarks reproducible without aircraft hardware.
- The repo's README and any future App Store / landing copy must NOT promise compatibility with hardware we haven't tested.
- The "hardware truth first" line in `docs/architecture.md` is reinterpreted: truth means **wired and replayable**, not "class-compliant ATC headset adapter".

## Non-decisions (deferred)

- Which specific class-compliant USB-C audio interfaces will be on the support matrix once wired baseline ships.
- Whether to ship a recommended headset list in App Store description.
