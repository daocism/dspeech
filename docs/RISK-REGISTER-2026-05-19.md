# Dspeech MVP risk register — 2026-05-19

Scope: risks that can break the F1–F8 PRD gate (`docs/product/prd-ios-mvp.md`) or violate the non-negotiables in `CLAUDE.md` (notably ADR 0002 local-only default) between this commit and Andrei's on-device F6/F7/F8 run on iPhone 17 Pro Max / iOS 26. Read-only against source; cites filenames + ADRs as evidence.

Severity scale: **high** = ships broken product or violates a hard rule. **med** = degrades a PRD gate or causes an App Store / device-run rejection. **low** = cosmetic / recoverable in a patch.

Likelihood scale: **likely** = will occur under normal MVP run; **possible** = depends on device path or pack catalog state; **unlikely** = needs a specific combination of conditions.

Owner roles match `docs/PLAN-2026-05-19.md` wave allocation.

---

## R-001 — Apple Translation framework on-device pack availability

- **Severity:** high
- **Likelihood:** possible
- **Description:** `TranslationService` (see `Dspeech/Core/Translation/TranslationService.swift`, `TranslationLanguagePackManager.swift`) depends on Apple Translation framework's offline pack catalog. On iOS 26, a (source → target) pair may report `LanguageAvailability.Status.unsupported` or `.supported` but require a user-initiated download. With `PrivacyMode.localOnly` (ADR 0002), missing pack must NOT silently fall back to cloud — the PRD §1 main-view flow requires a one-tap "Download pack — N MB" CTA.
- **Detection signal:**
  - Architect Context7 query against `/websites/developer_apple` for `TranslationSession` + `LanguageAvailability` returns an iOS-26 surface incompatible with what `AppleTranslationService` calls.
  - Runtime: a translation toggle ON for a pair that ships no on-device pack produces a `TranslationService` error that surfaces as an empty gloss line or a thrown error reaching the View.
  - Test: `TranslationOverlayViewModelTests` covering `.localOnly` + unavailable-pack pair returns the "download required" state, not nil.
- **Mitigation:**
  1. Architect must verify the offline-pack API surface before W2a freezes the protocol (already mandated in PLAN W1).
  2. If the framework cannot guarantee offline-only behavior under `.localOnly`, defer F3 from MVP gate and record in **ADR 0007 (translation deferral)** — already pre-authorized in PLAN §"Stack-canon".
  3. UI: render an explicit "Pack required — N MB" CTA per PRD §1.3; never show empty translation rows.
  4. Add a `TranslationServiceError.packUnavailable(source, target)` case and surface it at the ViewModel boundary (single-boundary policy, `CLAUDE.md` error rules).
- **Owner:** architect (W1) → implementer-translate (W2a) → tester-translate (W2b).

---

## R-002 — AVAudioSession USB-C route detection on iPhone 17 Pro Max

- **Severity:** high
- **Likelihood:** likely on first device run
- **Description:** ADR 0004 mandates wired/cable testing without buying hardware. The Settings audio-source picker (PRD F5) enumerates routes via AVAudioSession; class-compliant USB-C audio interfaces on iPhone 17 Pro Max present as `AVAudioSessionPort.usbAudio` (or similar) but route discovery in the Simulator is fake (declared in PLAN §"Residual risks"). Picker behavior diverges between sim and device.
- **Detection signal:**
  - `AudioRouteChangeObserver` (`Dspeech/Core/Audio/AudioRouteChangeObserver.swift`) fires `routeChange` with `reason == .newDeviceAvailable` on physical insertion but never on Simulator.
  - On device: AVAudioSession `currentRoute.inputs` lacks the USB-C port even with a class-compliant interface plugged in (driver / category mismatch).
  - "Test level" meter reads −∞ dBFS when source is selected but no AGC.
- **Mitigation:**
  1. Use `AVAudioSession.Category.playAndRecord` with `AVAudioSession.CategoryOptions.allowBluetooth, .allowAirPlay, .allowBluetoothA2DP` removed (mic-input scope); explicitly call `setPreferredInput(_:)` to the chosen `AVAudioSessionPortDescription`.
  2. Surface a "Route lost" banner driven by `AudioRouteChangeObserver` + auto-pause ASR when `oldDeviceUnavailable` fires mid-session (covers cockpit cable unplug).
  3. Andrei-gated device test in W10 hand-off must include: built-in mic, USB-C class-compliant audio adapter, AirPods (degraded, warning shown).
  4. Reject the picker shipping with sim-only validation — `docs/PLAN-2026-05-19.md` already declares this device-gated.
- **Owner:** implementer-audio (W3a) + tester-audio (W3b); device verification → Andrei (W10).

---

## R-003 — SFSpeechRecognitionTask 1-minute audio boundary

- **Severity:** high
- **Likelihood:** likely
- **Description:** `SFSpeechRecognitionTask` historically caps a single recognition request at ~1 minute of audio on iOS; the task ends with no error or with `kAFAssistantErrorDomain` 209/216 and stops emitting partial results. `AppleSpeechLiveTranscriptionEngine` (`Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift`) drives F1 — without a rolling-segment strategy, F6 (crash-free 60 min continuous ASR) and F7 (≤25%/h battery) cannot pass.
- **Detection signal:**
  - 60-minute continuous run produces transcript activity that flat-lines after ~60 s and no new `TranscriptSegment.Source.live` segments arrive.
  - `SFSpeechRecognitionTask` delegate emits `task(_:didFinishSuccessfully:)` with no audio EOF triggered by the app.
  - F6/F7 device run from Andrei reports "transcript stopped advancing".
- **Mitigation:**
  1. Engine must rotate the `SFSpeechAudioBufferRecognitionRequest` on a fixed cadence (≤50 s) — finalize the current request, start a fresh one, splice segment IDs to keep the visible transcript continuous.
  2. Tests: `AppleSpeechLiveTranscriptionEngineTests` (if not already present) must drive a simulated 75-s buffer feed and assert ≥2 rotations occurred and the visible segment count is monotonic.
  3. Surface a `LiveTranscriptionEngineError.recognitionTaskInterrupted` if rotation fails twice in a row; ViewModel reports to user but does not crash.
- **Owner:** implementer-translate's neighboring ASR maintainer (out of scope this mission unless touched); flagged for tech-lead to assign W11 follow-up if engine lacks rotation logic. Architect (W1) confirms current behavior during stack-canon read.

---

## R-004 — Background audio entitlement state

- **Severity:** med
- **Likelihood:** unlikely (current config is correct)
- **Description:** `Dspeech.xcodeproj/project.pbxproj` does **not** declare `UIBackgroundModes = audio` (grep confirmed lines 145–146). This satisfies PRD F8 (no covert background capture) and ADR 0002 (no off-device data path) by construction — backgrounding will cause AVAudioSession to interrupt and ASR to stop. Risk is that a future change adds the entitlement to "fix" a perceived bug.
- **Detection signal:**
  - `grep -n 'UIBackgroundModes' Dspeech.xcodeproj/project.pbxproj` returns any match → regression.
  - Field report: app continues transcribing audio after pressing Home.
  - Test: `DspeechUITests` smoke that backgrounds the app and asserts `scenePhase == .background` triggers `LiveSession.stop()`.
- **Mitigation:**
  1. Add a verifier grep to W7 gate: `grep -n '"UIBackgroundModes"' Dspeech.xcodeproj/project.pbxproj` must return 0 unless an ADR 0007+ approves it.
  2. ViewModel listens to `scenePhase` and calls `engine.stop()` on `.background` — already required by PRD F8.
  3. Document in About sheet (`AboutView`) that backgrounding stops transcription on purpose.
- **Owner:** integrator (W5) wires `scenePhase`; verifier (W7) adds the grep guard.

---

## R-005 — ADR 0002 privacy regression (silent cloud path)

- **Severity:** high (rule violation, not bug)
- **Likelihood:** unlikely if guards stay, likely without them
- **Description:** Any new `URLSession` / `URLRequest` / outbound socket added under `Dspeech/Core/Translation/` or `Dspeech/Core/ASR/` while `PrivacyMode.localOnly` is the boot default silently violates ADR 0002 and the badge `LOCAL` becomes a lie. Reviewer must reject; verifier must catch mechanically.
- **Detection signal:**
  - PLAN W7 verifier rule: `grep -rIn "URLSession\|URLRequest\|HTTPSURL" Dspeech/Core/Translation/` must return 0.
  - Equivalent grep over `Dspeech/Core/ASR/` should also return 0 unless an explicit cloud-ASR adapter ships (ADR not yet written).
  - Reviewer prompt explicitly checks for "phones home under .localOnly".
- **Mitigation:**
  1. Extend W7 grep to cover `Dspeech/Core/ASR/` and `Dspeech/Core/Audio/` as well.
  2. Lint-style assertion in `PrivacySettings` change-handler: any transition `localOnly → allowCloudFallback` requires explicit user confirmation (PRD §1.2 disclosure).
  3. `Network.framework` (`NWConnection`, `NWBrowser`) names added to the grep.
  4. Reviewer (W6) reads ADR 0002 verbatim before scoring.
- **Owner:** reviewer (W6) + verifier (W7).

---

## R-006 — App Store review surface: mic usage string + privacy manifest

- **Severity:** med
- **Likelihood:** possible (deferred until submission, but blocks W10+)
- **Description:** `project.pbxproj` sets `INFOPLIST_KEY_NSMicrophoneUsageDescription` and `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` in **Russian only**. App Store Connect requires the string to be readable in the app's primary localization; if `CFBundleDevelopmentRegion` is `en` (default when not overridden), a Russian-only purpose string is a rejection risk under App Review Guideline 5.1.1. Additionally there is **no `PrivacyInfo.xcprivacy`** in the repo (find returned 0 hits) — Apple has required a privacy manifest for new app submissions since 2024, and Speech / AVAudioEngine + UserDefaults are categories that require declaration.
- **Detection signal:**
  - `find . -name PrivacyInfo.xcprivacy` returns no matches.
  - Bundle `CFBundleDevelopmentRegion` is unset → defaults to "en", mismatch with `NSMicrophoneUsageDescription` value.
  - TestFlight submission warning: "Missing privacy manifest" / "NSMicrophoneUsageDescription not localized".
- **Mitigation:**
  1. Add an English `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription` in the base `.xcstrings` (project already has `LOCALIZATION_PREFERS_STRING_CATALOGS = YES`); keep Russian as a localization rather than the canonical Info.plist key.
  2. Add a `PrivacyInfo.xcprivacy` declaring: tracking=NO, tracking domains=∅, collected data types=∅ (consistent with ADR 0002), required-reason API usage for `UserDefaults` (CA92.1 — app functionality), `SystemBootTime` if used, `FileTimestamp` if used.
  3. Defer submission per CLAUDE.md ("No App Store submission … without explicit Andrei sign-off"), but ship the manifest so W10 hand-off is clean.
- **Owner:** docs-writer (W9) drafts the manifest; integrator (W5) adds the file to the target.

---

## R-007 — Live waveform / level-meter render cost on long sessions

- **Severity:** med
- **Likelihood:** possible
- **Description:** PRD F5 "Test level" meter and any live waveform on the main view re-render on the audio I/O thread cadence (typically ~10–43 Hz from `AVAudioEngine` taps). A naive SwiftUI `Canvas` or `TimelineView` redrawing the full waveform every buffer kills the F7 battery budget (≤25%/h) and steals ASR CPU, risking F6 (60-min stability). Reading from a `Float` RMS published via `@MainActor @Observable` at >30 Hz is enough to stall the run loop on iPhone 15-class devices.
- **Detection signal:**
  - Instruments → Energy Log: SwiftUI rendering ≥ 25% of CPU during idle "level-meter only" state.
  - Frame hitches reported by `MetricKit` `MXAnimationMetric.scrollHitchTimeRatio` > 0.05.
  - Battery drain measurement at W10 exceeds 25%/h with ASR off but meter on.
- **Mitigation:**
  1. Throttle published `inputLevel` to ≤10 Hz at the `AudioLevelMeterViewModel` layer (planned owner per PLAN W3a).
  2. Use a single `CADisplayLink`-driven `TimelineView(.animation)` for the bar, not per-buffer `@Published` writes.
  3. Tests: `AudioLevelMeterViewModelTests` asserts publish cadence ≤10 Hz under a synthetic 44.1 kHz buffer feed.
  4. Andrei device run measures the meter-only / ASR-only / both modes separately at W10.
- **Owner:** implementer-audio (W3a) + tester-audio (W3b); device confirmation Andrei.

---

## R-008 — Localization completeness (ru / en parity)

- **Severity:** med
- **Likelihood:** likely
- **Description:** Project uses string catalogs (`LOCALIZATION_PREFERS_STRING_CATALOGS = YES`). User-facing strings are currently a mix of Russian (Info.plist purpose strings, "Конфиденциальность / Privacy" section name per ADR 0002) and English (PRD references, ADR copy). With aviation domain users (PRD §"Users") spread across English-only ATC and Russian-speaking student pilots, partial localization shows half-translated UI in either language and undermines the "for pilots" positioning.
- **Detection signal:**
  - String catalog audit: any key with `state = "new"` or `state = "stale"` for `ru` or `en`.
  - UI smoke run under `-AppleLanguages '(en)'` shows Russian-only strings (or vice versa).
  - PR for First-run cards introduces literals not extracted via `String(localized:)`.
- **Mitigation:**
  1. Implementer-firstrun (W4a) and implementer-translate (W2a) must use `String(localized:)` for every visible string; no `Text("…")` with a non-key literal in shipped code.
  2. W7 verifier adds: `grep -rIn 'Text("' Dspeech/App/` flags candidates needing review.
  3. String catalog `Localizable.xcstrings` must reach **ru** and **en** state=translated for every key by W7.
  4. About sheet displays the active locale + a hint to switch in iOS Settings if the wrong language is shown.
- **Owner:** implementers (W2a / W3a / W4a) write extractable strings; docs-writer (W9) verifies catalog completeness.

---

## R-009 — Audio session interruption recovery (phone call / Siri / alarm)

- **Severity:** med
- **Likelihood:** likely
- **Description:** Cockpit phone is often a personal device. Incoming call, Siri activation, or a calendar alarm fires `AVAudioSession.interruptionNotification` with `.began`; on `.ended` we must check `shouldResume` and restart capture cleanly. If `AppleSpeechLiveTranscriptionEngine` does not handle this, F6 (60-min stability) fails the moment any system audio steals the session.
- **Detection signal:**
  - On device: triggering Siri mid-listen leaves the transcript area frozen with no error to the user.
  - `AVAudioSession.interruptionNotification` observer absent in `AudioCaptureService` (`Dspeech/Core/Audio/AudioCaptureService.swift`) — quick read confirms whether it's wired.
  - Test: `AudioCaptureServiceTests` injecting a fake interruption notification asserts capture pause + resume.
- **Mitigation:**
  1. `AudioCaptureService` subscribes to `AVAudioSession.interruptionNotification`; on `.began` pause engine + emit `LiveSession.State.interrupted(reason:)`; on `.ended` with `shouldResume` restart engine + clear state.
  2. UI shows a chip "Прервано системой / System interrupted — resuming" with 3-s auto-dismiss.
  3. Surface this as a residual risk to Andrei for the device run — explicitly attempt Siri / incoming call during the 60-min battery test.
- **Owner:** implementer-audio (W3a) or ASR maintainer if engine owns the AVAudioSession; reviewer (W6).

---

## R-010 — Accessibility identifier drift breaking XCUITest gates

- **Severity:** low
- **Likelihood:** possible
- **Description:** `CLAUDE.md` mandates `accessibilityIdentifier("kebab-case")` on every UI element a XCUITest needs to target. The W7 verifier rule "`accessibilityIdentifier(` present on every new control referenced in UI tests" only catches misses statically — renames in W5 integration (ContentView, SettingsSheet, DspeechApp) can break UI smoke tests in a way that lingers as "flaky" rather than "wrong".
- **Detection signal:**
  - `DspeechUITests` smoke fails to find an element by identifier; XCTest prints "No matches found for…".
  - W5 integrator (PLAN W5 owns ContentView/SettingsSheet/DspeechApp) renames an existing identifier from a kebab-case key not also updated in tests.
- **Mitigation:**
  1. Centralize identifiers in a `AccessibilityIdentifiers.swift` enum referenced from both view and test side (single source of truth, no string literals).
  2. W7 grep: `grep -rIn 'accessibilityIdentifier("' Dspeech/App/` cross-referenced with `grep -rIn '"[a-z-]\+"' DspeechUITests/` to flag dangling refs.
  3. Reviewer (W6) verifies no PR removes an identifier referenced by a test still on disk.
- **Owner:** integrator (W5) + tester roles (W2b / W3b / W4b); reviewer (W6) gate.

---

## Cross-references

- `CLAUDE.md` (root and repo) — non-negotiables.
- `docs/PLAN-2026-05-19.md` — wave allocation, W7 verification gate.
- `docs/adr/0002-privacy-local-only-default.md` — privacy contract for R-001, R-005, R-006.
- `docs/adr/0004-no-hardware-purchase-cable-testing.md` — device-path scope for R-002, R-007, R-009.
- `docs/product/prd-ios-mvp.md` — F1–F8 gates referenced throughout.

## Out of scope for this register

- F1 latency / WER targets — owned by `docs/eval/asr-benchmark-plan.md`.
- Pricing / hourly model — owned by `docs/product/hourly-package-model.md`; not an MVP-gate risk.
- Hermes sales bot integration — outside the app target.
- App Store submission, IAP / billing risks — gated by ADR 0006; outside this mission.
