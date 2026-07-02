# Dspeech iOS

Dspeech is an iOS-first aviation communication companion: receive-only cockpit/intercom
audio capture, real-time on-device ATC transcription, pilot-voice filtering, and optional
on-device translation — the original transcript always stays primary.

Domain: `dspeech.com`.

## Current state

- Platform: iOS 26+ (iPhone + iPad), macOS 26 / Xcode 26, Swift 6 strict concurrency,
  warnings-as-errors both configs.
- Privacy: local-only by default and in fact — no cloud code paths exist (ADR 0002).
  The LOCAL badge on the control bar is a hard product rule. Optional model packs are
  the only network surface: pinned-revision HuggingFace downloads, per-file SHA-256
  verified, resumable, offline-aware.
- ASR: Apple `SFSpeechRecognizer` (default) + WhisperKit (multilingual, selectable) —
  ADR 0009/0011. A third streaming engine was added and then removed the day it was
  first measured on real audio (ADR 0014): wiring-first-measure-later is banned here.
- Voice filter: on-device FluidAudio speaker identification separates dispatcher audio
  from own-crew transmissions, with callsign-aware classification (ADR 0007/0008).
- UI: SwiftUI with the iOS 26 Liquid Glass design language on chrome surfaces (ADR 0013),
  two-tier badge system, haptics, dark cockpit theme, full Dynamic Type + VoiceOver
  support, 11 fully confirmed locales.
- Persistence: crash-tolerant JSONL transcript store with session history, duration/
  engine/locale metadata, text + JSONL export, and opt-in retention cleanup.
- Tests: 960+ Swift Testing domain tests (incl. seeded + PropertyBased property suites
  and pinned snapshot suites), XCUITest core flows, accessibility-audit sweeps
  (contrast/clipping/hit-region × Dynamic Type × en/de/ru).

## Local commands

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# one-command authoritative gate: format lint -> device-arch compile -> unit + core UI
scripts/local-gate.sh

# a single suite
xcodebuild -project Dspeech.xcodeproj -scheme Dspeech \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -testPlan Dspeech -only-testing:DspeechTests CODE_SIGNING_ALLOWED=NO test
```

If `xcodebuild` says only CommandLineTools are active, keep `DEVELOPER_DIR` as above or
set Xcode globally with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

Real-audio verification (fixtures through the real engines) and release gates:

```bash
scripts/verify-primary-scenario.sh          # real ATC fixtures through real ASR
python3 scripts/release/check-release-policy.py --source-only
python3 scripts/release/check-listing-metadata.py
scripts/release/check-release-ready.sh      # full pre-flight
```

## Where things live

- `docs/adr/` — binding architecture decisions (0001–0013).
- `docs/PLAN-*.md` — iteration plans; `docs/ai-kb/current-context.md` — rolling state.
- `docs/product/` — pricing, listings (11 locales), privacy policy draft, release docs.
- `Dspeech/Core/` — engines, audio, voice filter, persistence (protocol-first).
- `Dspeech/Tools/` — SpeakerEval + ReplayKit host CLIs for real-model evaluation.

## Not in this repo (deliberate)

No billing/StoreKit (ADR 0003 implementation pending), no background-audio mode
(ADR 0010), no cloud ASR, no analytics/tracking of any kind.
