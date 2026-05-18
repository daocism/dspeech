# Audio input matrix

Date: 2026-05-18. Status: draft. Tied to ADR 0004 ("no hardware purchase, wired-only testing").

## Purpose

Define which audio input paths Dspeech officially supports, which are demo-only, and what the expected SNR/latency profile is for each. This matrix is the contract between the Settings audio-source picker (`prd-ios-mvp.md` F5) and the benchmark plan.

## Input paths

| # | Path | Hardware needed | Expected SNR (dB) | Latency added (ms) | Status | Notes |
|---|---|---|---|---|---|---|
| 1 | Built-in iPhone mic | none | 5–15 (loud cockpit) | 0 | Demo only | Picks up engine + cabin noise; usable only for trying the app |
| 2 | AirPods Pro 2 / AirPods 4 ANC mic | AirPods | 8–18 | 80–120 (BT codec) | Stretch | Bluetooth latency variable; warn user |
| 3 | USB-C → 3.5 mm TRRS adapter + headset mic | Andrei-owned headset, no buy | 15–25 | 5–15 | Supported v1 | Primary supported path |
| 4 | USB-C → class-compliant USB audio interface (e.g. iRig Pro Duo, Bose A30 BT) | Owned by user, NOT purchased by project | 20–30 | 5–10 | Supported v1 | Best quality; class-compliant required |
| 5 | Cabled intercom tap (mono out from intercom panel → 3.5 mm TRRS) | User-owned aircraft / sim setup | 25–35 | 0–5 | Supported v1 (validation path) | The "wired-only test path" of ADR 0004 |
| 6 | Lightning audio | none (legacy iPhones) | n/a | n/a | Out of scope | iPhone 15+ is USB-C |
| 7 | Bluetooth aviation headset (Bose A30, Lightspeed Delta Zulu over BT) | User-owned | 15–25 | 80–150 | Best-effort | BT codec is the bottleneck |

## Settings UI mapping

Picker shows: `Built-in mic (demo)`, `Wired (3.5 mm or USB-C)`, `AirPods / Bluetooth (best-effort)`. Internally maps to AVAudioSession route categories; we do not expose the full route enum to the user.

When a path with SNR < 10 dB is detected at runtime (via input-level meter over a 3-s sample), surface a yellow toast: "Сигнал слабый — попробуйте проводное подключение." Never block recording.

## Format normalization

- Capture at AVAudioSession's preferred rate (typically 48 kHz on iPhone 15+).
- Downsample to 16 kHz mono PCM 16-bit before ASR (matches corpus format).
- All ASR adapters consume the normalized stream; format conversion lives outside the adapter.

## Benchmark coverage

Per the corpus spec, each ASR engine is benchmarked against pre-recorded files at the corpus format, so input-path variability is decoupled from engine choice. Live-mic A/B is a separate smoke test per release, with one fixed playback rig (Andrei's laptop speaker into iPhone mic at fixed distance), reported but not gating.

## Open questions (Andrei action required)

- Which physical wired adapter / cable does Andrei already own? Confirm so we can document the exact part numbers in README (not buy).
- Does Andrei plan to wire into a sim intercom panel for validation? If yes, document the panel make/model so we can reproduce SNR profile.

## References

- ADR 0004, `prd-ios-mvp.md`, `asr-benchmark-plan.md`, `evaluation-corpus-spec.md`.
