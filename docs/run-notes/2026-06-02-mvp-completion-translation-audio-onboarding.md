# MVP completion — first-run, background-stop, translation, audio source (2026-06-02)

Branch: `feat/mvp-completion-2026-06-02` (5 commits on top of `main`). Build + full
test suite green on iPhone 17 Pro / iOS 26.4, **zero warnings**; device-arch
(`generic/platform=iOS`, arm64-apple-ios26.0) compiles clean (signing aside).

## PRD gates closed
- **§3 First-run onboarding** — `OnboardingState` (@Observable + storage) + `OnboardingView`
  (3 cards: receive-only / local-by-default / wire-for-accuracy), shown once via
  `fullScreenCover`. UITest `testFirstRunOnboardingShowsCardsThenRevealsTranscript`.
- **F8 Background stop** — `CaptureCoordinator.stopForBackground()` + `ContentView`
  `scenePhase == .background` stops ASR cleanly (no covert capture). `CaptureCoordinatorTests`.
- **F3 On-device translation** — `Core/Translation/{TranslationServiceProtocol,TranslationService}.swift`:
  `AppleTranslationService` via `TranslationSession(installedSource:target:)` (sync,
  non-throwing, installed-only) + `session.translate`; `LocalTranslationService` decorator;
  typed `TranslationServiceError`. `TranslationSettings` (enable + target catalog).
  `LiveTranscriptionViewModel` translates each finalized segment off-main with per-segment
  UUID token guards (no stale write after reset/supersede); `ContentView` "Перевод" toggle,
  italic gloss line, Settings target picker, and a `@Sendable .translationTask` driving
  `prepareTranslation()` (the only pack-download path — Apple owns transport, ADR 0002).
  Local-only; defaults OFF; no fake AI (demo `.demo` segments never glossed).
- **F5 Audio source picker** — `PortSnapshot.uid`; `AudioSettings` persists chosen input
  (uid + port type); `PreferredInputResolver` (uid → type fallback); `AudioSourceController`
  wraps routing+settings, applies preference at launch, `Settings` "Источник звука" picker.

## Adversarial review (2 passes, all confirmed findings fixed)
Pass 1 (15 agents): 8 confirmed → fixed. Notably: removed a fake-AI surface where the
demo fixture's canned Russian rendered as "translation" (glossText now skips `.demo` and
returns only real engine output); armed `translationConfig` in `onAppear` so persisted-ON
translation triggers the download path on cold launch; per-segment token lifecycle in
`maybeTranslate`. Pass 2 (5 agents): 1 confirmed (token guards untested by a synchronous
fake) → added a controllable-suspension race test; removed a double-retranslate/flicker.
Concurrency/privacy/hard-rules verified clean (no network path; LOCAL badge always visible;
real toggle; no placeholders).

## Deferred (documented, non-blocking)
- **F5 live input-level meter** — picker + persistence (the F5 gate) shipped; the "test
  level" meter is deferred: device-only-unverifiable and a second `AVAudioEngine` on the
  shared `AVAudioSession` would risk the proven route-health/ASR path.
- **`translationUnavailable` not surfaced in UI** — flag is set (pack missing/declined) but
  no view reads it; iOS already presents the system pack-download sheet on enable. A future
  in-app "language pack needed / retry" affordance would close PRD F3 UX.
- **Suppressed (voice-filtered) segments are still translated** — wasted work, never shown.
- **`.translationTask` cold-launch arming has no automated test** — launching a UITest with
  translation pre-enabled risks the system download sheet (non-deterministic); restore logic
  is covered at the `TranslationSettings` unit layer instead.

## Translation reference
Core translation logic was ported from the unmerged `feat/mvp-completion-2026-05-19` branch
(which had persistent review blockers and predates the voice-filter architecture, so it was
NOT mergeable). Re-authored in repo style (no DocC), with that branch's MAJOR-5 asymmetric-
trim fixed (both layers forward trimmed text). Apple API surface independently re-verified
against Apple DocC JSON + that branch's verification table.

## Install status (device)
Project is automatic-signing, bundle `com.dspeech.app`, deployment iOS 26.0, mic+speech
usage strings + `ITSAppUsesNonExemptEncryption=NO` present. No Apple Developer Team ID is
stored in 1Password. Device install needs Andrei's Apple ID in Xcode + a connected/trusted
iPhone (paired iPhone 17 Pro Max present but currently `unavailable`). See the session
runbook: add Apple ID in Xcode → select Personal Team on the Dspeech target → connect iPhone
→ Run → trust the dev cert on-device.
