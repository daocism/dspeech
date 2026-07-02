# Dspeech — Night polish mission, 2026-07-02

99 mid-size tasks toward "perfectly polished, production-ready", derived from a 5-agent
audit (UI/UX, core engine, tests/CI, product/App-Store, deps/OSS) on `main` @ `3123265`.
Executed autonomously overnight on branch `feat/night-polish-20260702` (+ child branches
per phase where useful). Hard constraints honored throughout: local-only privacy (ADR 0002),
no StoreKit/billing (rule 7), no App Store submission (rule 6), no background-audio mode
without a superseding ADR (ADR 0010), no device-lane claims (simulator/host verification
only, per owner's standing 2026-06-13 suspension), no CIS in marketing surfaces, existing
pbxproj IDs untouched.

Deferred-to-Andrei items explicitly NOT executed here: ADR 0010 background audio,
ATCVoiceIndicator badge rendering decision, ADR 0003 monetization non-decisions, CDN
mirror strategy, `.allowCloudFallback` policy, paid Developer Program enrollment,
publishing the privacy-policy URL, any submission step.

## Phase A — Dependencies & supply chain (8)
- [x] A1. FluidAudio: raw-revision pin (`8048812` = 0.14.7) → exact **0.15.4** in the app; fix API breaks (DiarizerManager de-async etc.) in `Core/VoiceFilter/*`.
- [x] A2. SpeakerEval tool: lockstep bump FluidAudio 0.14.7 → 0.15.4 (must match app).
- [x] A3. `ParakeetStreamingAdapter` adaptation to FluidAudio 0.15.x streaming backend; EOU reset-after-segment regression tests stay green.
- [x] A4. `scripts/release/check-release-policy.py` supply-chain pin checks updated for the new FluidAudio pin (+ any new packages), gate stays meaningful.
- [x] A5. Adopt **swift-collections**: `Deque` replaces O(n) `removeFirst()` queue in `SerialBufferRouter` (+ anywhere else profiling justifies).
- [x] A6. Adopt **swift-async-algorithms** (dep only + first use seam; consumer lands in C5).
- [x] A7. Adopt **swift-snapshot-testing** (test target only) + snapshot support infra.
- [x] A8. Adopt **PropertyBased** (x-sheep, Swift-Testing-native PBT with shrinking) for NEW property suites; existing seeded-PRNG suites stay as-is.

## Phase B — Core dedup / structural refactor (7)
- [x] B1. Shared throwing `ApplicationSupportDirectory` helper — replace the 8+ scattered `FileManager.urls(...).first!` copies.
- [x] B2. Extract generic model-install-state storage from the 3 ~95%-identical stacks (WhisperKit / Parakeet / ModelPackState), ~1500 → ~500 lines + 3 config structs.
- [x] B3. Extract generic `PinnedModelInstaller` engine (download/stage/verify/atomic-install), parameterized by manifest+checksums.
- [x] B4. Backport per-file SHA-256 verification to the WhisperKit model installer (closes the fail-open integrity gap; trivial after B3).
- [ ] B5. Shared `AVAudioEngineTapSession` primitive encoding the `format: nil` + `@Sendable` tap tribal knowledge once; migrate `LiveAudioCaptureConduit`.
- [ ] B6. Migrate the other 3 capture wrappers (CallsignDictation, VoiceEnrollment, InputLevelMeter) to the shared tap primitive.
- [x] B7. Move `FakeAudioSessionRouting` out of production source (`Core/Audio/AudioSessionRouting.swift`) into the test target.

## Phase C — Core features & robustness (10)
- [x] C1. Resumable model downloads: HTTP range-resume for partial files (multi-hundred-MB packs on cellular) in the shared installer.
- [x] C2. Offline-specific failure taxonomy: distinguish `.notConnectedToInternet` from generic network failure in installer errors + user copy.
- [ ] C3. Download pause/resume UX in Settings (builds on C1; `cancelDownload` already exists).
- [x] C4. Phone-call interruption handling: classify call-type AVAudioSession interruptions, clean pause + honest banner + regression test (no CallKit entitlement, receive-only classification).
- [x] C5. Debounce partial-hypothesis UI re-renders via swift-async-algorithms (perf/energy on long sessions).
- [ ] C6. Richer transcript export: timestamped `.txt` + structured `.jsonl` share options in session history detail.
- [ ] C7. Session summary metadata surfaced: duration, engine used, recognition locale in history rows + detail header.
- [ ] C8. Transcript storage usage surfaced in Settings + opt-in auto-cleanup of old sessions (default OFF, honest copy).
- [x] C9. Parakeet UI strings: hand-author the missing `Localizable.xcstrings` catalog entries (headless-safe JSON edit) so Parakeet picker/install UI localizes properly.
- [ ] C10. Parakeet confidence-0 / VERIFY-badge behavior review: keep honest, avoid badge noise (documented decision in code, no product-semantics change).

## Phase D — iOS 26 Liquid Glass UI (18)
Glass on chrome only (never scrolling content), `.regular` variant over live transcript,
one `GlassEffectContainer` per cluster, Reduce-Transparency/Motion/Increase-Contrast
verified per cluster. LOCAL/CLOUD badge legibility is a hard gate (rule 4).
- [x] D1. `DspeechTheme` + `AccentColor.colorset`: centralize the scattered hardcoded tints.
- [x] D2. `GlassEffectContainer` + `.glassEffect` on the MainControlBar button cluster.
- [x] D3. StartButton glass treatment (prominent tint, `.contentShape` hit-area fix, `.buttonBorderShape(.circle)`), glow ring kept Reduce-Motion-aware.
- [x] D4. PrivacyBadge + RouteHealthChip glass capsules; LOCAL/CLOUD badge legibility under Reduce Transparency verified.
- [x] D5. BottomLeftControls + LiveFailureBanner glass backing.
- [x] D6. HintBubble glass rework (floating overlay at intrinsic size, never inline in contested rows).
- [x] D7. Status banners (Route/BackgroundStop/Persistence/TranslationFailure) glass tier.
- [x] D8. FilteredCountPill + FilteredTransmissionsReviewSheet polish.
- [x] D9. `glassEffectID` morph transitions: start↔stop button, privacy-badge state changes.
- [x] D10. Transcript card entrance transition (fade+rise), Reduce-Motion respected.
- [ ] D11. Reduce-Motion audit: honor `accessibilityReduceMotion` in ALL remaining `withAnimation` sites.
- [x] D12. Haptics: `.sensoryFeedback(.impact)` on Start/Stop.
- [x] D13. Haptics: `.success` on model-pack install + enrollment completion; warning feedback on Clear confirm.
- [x] D14. Badge visual hierarchy: two tiers (filled vs outline) across the 6 competing capsule chip types; `lineLimit(1)` + `minimumScaleFactor` everywhere.
- [x] D15. Typography pass: contrast tier between utterance text (monospaced) and metadata chrome.
- [x] D16. Settings sheet presentation polish (glass chrome, detents).
- [x] D17. SessionHistory + Onboarding visual polish to the same design language.
- [x] D18. App icon dark + tinted variants (iOS 18+/26 expectation; currently single flat 1024px).

## Phase E — iPad & adaptivity (4)
- [ ] E1. Real iPad shell: `NavigationSplitView` (transcript + sidebar) replacing the letterboxed phone layout.
- [ ] E2. Settings/history as sidebar panes on regular width.
- [ ] E3. Landscape refinements; revisit the 720pt cap inside the split layout.
- [ ] E4. iPad UI tests updated for the split shell.

## Phase F — Tests (14)
- [ ] F1. Split `VoiceFilterTests.swift` (3200+ lines, 15 structs) into per-subsystem files, zero behavior change.
- [x] F2. Dedicated `AudioCaptureArbiterTests` (acquire/release/preemption contract, today only diffusely covered).
- [x] F3. `WhisperKitTranscriberAdapter` tests (zero coverage today).
- [x] F4. `ParakeetStreamingAdapter` tests (zero coverage today).
- [x] F5. `AppleSpeechEngineSupport` focused tests (restart-loop guard, error taxonomy — direct, not incidental).
- [x] F6. `OnDeviceLocaleAvailability` focused tests.
- [ ] F7. Snapshot suite: transcript cards × Dynamic Type {default, AX-XXXL} × {en, de}.
- [ ] F8. Snapshot suite: chips/badges/banners matrix (post-D14 two-tier system).
- [ ] F9. UI test: scripted live transcript + translation enabled simultaneously.
- [ ] F10. UI test: permission denied → Settings deep-link → re-request flow.
- [x] F11. Add `ru` sweep to AccessibilityAuditUITests (shipping default test locale is never audited today).
- [ ] F12. Dark-lock consistency UI test under system light mode (ui-quality light+dark requirement, honest for a dark-locked app).
- [ ] F13. PBT (PropertyBased): installer state machines — checksum mismatch / disk-full / resume branches.
- [ ] F14. VoiceOver affordance for transmission-card tap-to-expand (`accessibilityAction`) + UI test.

## Phase G — CI & build hygiene (8)
- [x] G1. Nightly scheduled lane: cron on main — ubuntu-safe jobs nightly + full macOS a11y sweep weekly (10× multiplier respected).
- [x] G2. Record resolved Xcode/simulator versions as a CI artifact (runner-image drift visibility).
- [x] G3. `.swift-format` config at repo root (explicit style instead of implicit default).
- [x] G4. Remove the checked-in `scripts/testdata/__pycache__/*.pyc` litter (gitignore already covers it).
- [x] G5. `scripts/local-gate.sh`: one-command local full gate (format + build device-arch + full suite + flake report).
- [ ] G6. Release-policy/check-release-ready updated for the new SwiftPM deps (pins validated).
- [x] G7. Pre-push hook: device-arch compile gate (proven to catch Swift-6 errors the sim lane misses).
- [ ] G8. CI uploads snapshot-test failure artifacts (diff images) on failure.

## Phase H — Localization (12)
- [x] H1. Reconcile `chore/l10n-core-semantics` (dspeech-w9): verify main supersedes all 32 keys, then delete branch + worktree (audit verdict: stale, do NOT merge).
- [x] H2–H10. Review + confirm the ~198 `needs_review` strings in each of 9 locales (de, es, fr, it, ja, ko, pt, uk, zh-Hans): verify correctness/terminology (aviation register), fix mistranslations, flip state to `translated`. One task per locale.
- [x] H11. `ru`: finish the last 10 `needs_review` strings.
- [ ] H12. Post-glass longest-locale re-verification (German AX sweep via existing UI tests).

## Phase I — App Store prep (no submission) (10)
- [x] I1. `docs/product/app-store/listing-zh-Hans.md` (only shipped locale without a listing draft).
- [x] I2. Fix stale docs: `testflight-setup.md` + `screenshot-plan.md` still claim the app icon is missing (it shipped 2026-06-02b).
- [ ] I3. Capture App Store screenshots (simulator, en + top locales) via `scripts/screenshots/`, review every frame with own eyes.
- [x] I4. Privacy-policy draft (`docs/product/privacy-policy.md`) ready for Andrei's publish decision (URL publishing itself stays blocked).
- [ ] I5. Run `xcrun privacyreport` on a fresh unsigned archive — FluidAudio/WhisperKit SDK privacy-manifest audit (open item from nutrition-labels mapping).
- [x] I6. Release checklist refresh to current reality (icon done, Parakeet engine, new deps).
- [x] I7. Metadata lint script: title/subtitle/keyword length + forbidden-region checks over `docs/product/app-store/listing-*.md`.
- [ ] I8. README refresh — honest current product/engineering state.
- [ ] I9. `docs/ai-kb/current-context.md` + `.ai/project-state.md` updated post-mission.
- [x] I10. ADR-0013: Liquid Glass design-language adoption (documents the D-phase rationale + a11y guarantees).

## Phase J — Verification & wrap-up (8)
- [ ] J1. Full local suite (unit + core UI), zero warnings, device-arch compile gate.
- [ ] J2. `DspeechFull` a11y/Dynamic-Type/multi-locale sweep locally, incl. Reduce-Transparency additions.
- [ ] J3. `scripts/verify-primary-scenario.sh` — real ATC fixtures through the REAL engines (primary-scenario proof).
- [ ] J4. Simulator visual review: screenshot the full view-state matrix, full-frame review of every image.
- [ ] J5. `run-asr-eval.py` real-engine eval: classification/WER not regressed vs the 92%/0.18 baseline.
- [ ] J6. CI green on all pushed branches/PRs (`gh run list` + root-cause fixes, no suppression).
- [ ] J7. Memory/pattern updates (project run-note + any global feedback patterns learned).
- [ ] J8. Final report: per-phase % dashboard, artifacts, SHAs.

## Execution notes
- Wave-based: parallel subagents with strictly disjoint file ownership; `Localizable.xcstrings` is single-owner for the whole night (serialized l10n batches).
- pbxproj edits (package additions) are done centrally, serialized, append-only (existing IDs untouched).
- Every wave: `swift format lint` + device-arch compile + affected test suites before commit; full suite before each push; `gh run list` after each push.
