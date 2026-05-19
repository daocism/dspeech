# Soak-Test Harness — 60-minute crash-free ASR session (F6)

Design-only specification. A fresh Claude session (or Andrei) follows this doc end-to-end to verify PRD gate **F6 — Crash-free session ≥ 60 min** on the target device. No code is changed by following this doc; any code hooks it asks for live in a separate, ADR-tracked PR.

Authoritative gate: `docs/product/prd-ios-mvp.md` row F6. Adjacent gates F7 (battery ≤ 25 %/h) and F8 (clean background stop) are tracked separately but use the same trace artifacts produced here.

## 1. Subject under test

- **Device:** iPhone 17 Pro Max, registered to Andrei's developer team, paired to `mac24` over USB-C cable (no Wi-Fi pairing — cable only, per ADR 0004 hardware-stability stance).
- **iOS:** 26.x release matching the simulator gate (`platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4` is the CI target; on-device must be ≥ 26.0).
- **App build:** Release configuration, `CODE_SIGNING_ALLOWED=YES`, ad-hoc signed with Andrei's personal team. Debug builds are disqualified — they distort allocations and CPU.
- **Privacy mode at session start:** `localOnly` (default). Soak does not test cloud — that has its own gate (not yet ADR'd).
- **ASR engine:** the shipped `AppleSpeechLiveTranscriptionEngine` against the `SpeechRecognitionService` contract. Demo `TranscriptSegment.Source.demo` is disallowed during soak.

## 2. Audio source

Two-tier source matrix; the soak run uses tier A. Tier B is a fallback if the lightning-to-USB rig is unavailable.

| Tier | Source | Wiring | Why |
|------|--------|--------|-----|
| A (primary) | 60-min loopback WAV of mixed VHF aviation chatter from the eval corpus | Mac24 → USB-C audio interface → Lightning/USB-C audio adapter → iPhone as wired audio input | Deterministic, repeatable, comparable run-over-run. Stresses the wired-input code path that ADR 0004 already gates as "must work before cockpit." |
| B (fallback) | Built-in mic in a quiet room with a Bluetooth speaker looping the same WAV at ~70 dBA SPL at the phone | Speaker plays Mac24 output; phone uses built-in mic | Used only if the USB-C audio rig fails. Documented in run notes; result still counts for F6 (zero crashes) but does NOT satisfy F1 WER. |

Loopback file requirements:
- 60 minutes ± 30 s, 16-bit PCM WAV, mono, 16 kHz.
- Drawn from `docs/eval/evaluation-corpus-spec.md` clips, concatenated; no synthetic silence > 5 s (engine should not be allowed to idle into a low-power state mid-soak — F6 measures continuous ASR).
- File checksum recorded in the run log so a future Claude can verify identity.

## 3. Pass criteria

A soak run **passes** iff all of the following hold:

1. **Zero crashes.** No `.ips` crash log is generated on the device under `Settings → Privacy & Security → Analytics & Improvements → Analytics Data` whose process name contains `Dspeech` during the run window. No `EXC_*` in `xcrun simctl spawn booted log show` or `idevicesyslog`.
2. **No hang reports.** No `dspeech-hang-*.ips` written by the OS Hang Detection subsystem.
3. **Memory growth ≤ 10 MB** between the t=00:05 baseline checkpoint and the t=60:00 final checkpoint (Allocations: "Persistent Bytes" delta, main app process, excluding XPC helpers). Transient peaks are allowed; the leak test is on the steady-state residual.
4. **No leaks reported by Leaks instrument** for objects retained > 5 s and > 1 KB. Anything reported must be triaged in the report; > 0 unexplained leaks = fail.
5. **Steady-state CPU < 35 %** sustained, measured as the mean over the t=05:00 → t=60:00 window in Time Profiler ("CPU Usage" track, single foreground process). Spikes ≤ 70 % are allowed if duration < 2 s.
6. **Audio engine continuity.** `SpeechRecognitionService` reports no `engine.didFail` events; `AudioCaptureService` reports zero unexpected route-change interruptions (the loopback wired route should not flap).
7. **Transcript visible at minute 60.** The on-screen transcript must contain a segment whose `endTime` is within 10 s of the soak end. Stalled transcription = fail, even with zero crashes.
8. **Privacy badge invariant.** The `LOCAL` badge must remain visible throughout (F4 invariant; F6 must not silently degrade it). Verified by screenshots at 0/30/60 min.

Any single failed criterion is a fail. There is no partial pass.

## 4. Instruments templates

Run all three concurrently via a single `xctrace` invocation against a custom `.tracetemplate`:

1. **Allocations** — track Persistent Bytes, mark generations at 5/15/30/45/60 min (manual via shortcut, or via signpost-driven auto-mark if §5 hooks land).
2. **Leaks** — default config; cycle-detection on.
3. **Time Profiler** — high-frequency sampling (1 ms), record CPU Usage + Thread State. Symbolicate against the dSYM produced by the same Release build.

Template lives at `tools/soak/Soak60.tracetemplate` (to be authored by a follow-up PR; this doc only specifies it). Until that template exists, Andrei opens Instruments and assembles the three instruments manually — checklist in §6.

## 5. Logging hooks (proposed, NOT changed by this doc)

This section is a request to a future PR. Adding the hooks is out of scope for the soak-harness design itself; the runbook below works with or without them (manual generation marks fall back to the keyboard shortcut).

Proposed `os_signpost` insertions (subsystem `com.dspeech.soak`, category `lifecycle`):

| Hook | Location | Signpost name | Payload |
|------|----------|---------------|---------|
| 1 | `LiveTranscriptionViewModel.start()` exit | `soak.start` | build version, engine identity |
| 2 | Every 5 minutes wall-clock via a `Timer` while soak flag is set | `soak.checkpoint` | minute index (0…60), resident-memory hint via `os_proc_available_memory()` |
| 3 | `SpeechRecognitionService` "engine restart" path (if any) | `soak.engine_restart` | reason code |
| 4 | `AudioCaptureService` route change | `soak.route_change` | from-route / to-route |
| 5 | `LiveTranscriptionViewModel.stop()` entry | `soak.stop` | reason (`user`, `background`, `error`) |

The soak flag should be a build-time `#if SOAK` or a launch argument `-SoakMode 1`, not a shipped Settings toggle. The doc deliberately does not pick — the implementer in the follow-up PR decides and writes an ADR if it crosses the privacy boundary.

## 6. Runbook (executable as-is)

Pre-run, on `mac24`:

```bash
# 1. Verify device is attached and trusted.
xcrun devicectl list devices | grep -i 'iPhone 17 Pro Max'

# 2. Build a Release IPA, sign with personal team, install on device.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Dspeech.xcodeproj -scheme Dspeech \
  -configuration Release \
  -destination 'platform=iOS,name=Andrei iPhone 17 Pro Max' \
  CODE_SIGNING_ALLOWED=YES \
  clean build

# 3. Confirm dSYM exists in DerivedData and note its UUID.
mdfind -onlyin ~/Library/Developer/Xcode/DerivedData 'kMDItemFSName == "Dspeech.app.dSYM"'

# 4. Charge phone to 100 %, disconnect, then reconnect cable (cable supplies data, not power, during the run — see §7).
```

Pre-run, on device:
1. Settings → Developer → enable "Show Hang Detection" toast.
2. Settings → Privacy & Security → Analytics Data → note current crash-log inventory (so any new `Dspeech-*.ips` is unambiguous).
3. Force-quit all other apps. Enable Do Not Disturb. Disable auto-lock (Settings → Display & Brightness → Auto-Lock → Never).
4. Plug in the USB-C audio adapter; verify the in-app `AudioInputService` picker shows the wired source as available.

Start the run:
1. On Mac24: `open` the Soak60 tracetemplate (or hand-assemble Allocations + Leaks + Time Profiler), target = "Andrei iPhone 17 Pro Max", process = `Dspeech`, **launch** (don't attach — we want full process lifetime).
2. Once Instruments has launched the app, immediately start the loopback WAV on the Mac audio interface feeding the phone.
3. In-app: confirm `LOCAL` badge visible, audio source = wired, then tap **Start**.
4. Record `t0 = $(date -u +%FT%TZ)` in the run log.
5. Take screenshot of the running app (volume-up + side button). File `soak-00m.png`.

During the run:
- At 05:00, 15:00, 30:00, 45:00, 60:00: press Cmd-Shift-G in Instruments to mark a generation (Allocations only) and a flag (all instruments). If signposts from §5 are live, generations auto-mark via `soak.checkpoint`.
- At 30:00: screenshot `soak-30m.png`. Glance — badge still `LOCAL`, transcript still advancing.
- Watch the live Persistent Bytes track; if growth exceeds 10 MB before 60:00, do NOT stop the run — let it finish, the trace is more valuable than the early abort.

Stop:
1. At t0 + 60 min ± 5 s: tap **Stop** in-app, then immediately stop the trace in Instruments.
2. Screenshot `soak-60m.png`.
3. Pull the run's `.ips` inventory: `xcrun devicectl device process inventory --device <udid>` and `xcrun devicectl device info logs --device <udid> --predicate 'process == "Dspeech"' --start "$t0"` → `soak-syslog.txt`.

## 7. Power / battery note

F6 only requires zero crashes; battery is F7. To keep F6 deterministic and avoid `LPM` (Low Power Mode) skewing the result, the cable provides data but **not power**. Use a USB-C cable that has been confirmed data-only, or use a powered USB hub between Mac24 and the phone with the upstream-power disabled. If the phone is charging, F7's measurement is meaningless and F6's CPU envelope shifts — both invalidated.

If a data-only cable isn't available, the run still counts for F6 zero-crash but NOT for F7 — note this explicitly in the report.

## 8. Exit artifacts

A passing soak produces, in `soak-runs/YYYY-MM-DD-HHMM/`:

- `Soak60.trace` — full Instruments trace, Allocations + Leaks + Time Profiler, all five generation marks present.
- `soak-00m.png`, `soak-30m.png`, `soak-60m.png` — screenshots.
- `soak-syslog.txt` — `devicectl` log dump for the `Dspeech` process across the run window.
- `soak-ips-inventory-pre.txt`, `soak-ips-inventory-post.txt` — crash-log filenames before/after; diff must be empty.
- `soak-run.md` — written by the runner. Must contain: device serial (last 4), iOS build, app build/version + commit SHA, loopback WAV checksum, t0, t_end, pass/fail per §3 criterion, any narrative anomalies, Instruments generation deltas (Persistent Bytes at 05/30/60 min), `os_signpost` event counts if §5 hooks are live.

A failing soak produces the same artifacts plus a `FAIL-<criterion>.md` per failed §3 criterion citing the specific trace marker or log line.

## 9. Re-run policy

- Single pass at the current SHA = F6 closed for that SHA only.
- Any change to `Dspeech/Core/Audio/`, `Dspeech/Core/ASR/`, `LiveTranscriptionViewModel`, or the `os_signpost` hooks themselves reopens F6 and requires a fresh soak run.
- Andrei is the only signatory on the F6 closure entry in the PLAN doc; a soak passed by Claude alone is reported, not closed.

## 10. References

- PRD: `docs/product/prd-ios-mvp.md` (F6 row).
- ADR 0001 (iOS-first), ADR 0002 (privacy), ADR 0004 (hardware/cable testing), ADR 0005 (app-first sequencing).
- Build/test commands: repo `CLAUDE.md`.
- Audio matrix: `docs/eval/audio-input-matrix.md`.
- ASR benchmark plan (corpus source for loopback WAV): `docs/eval/asr-benchmark-plan.md`.
