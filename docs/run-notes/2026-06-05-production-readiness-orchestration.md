# 2026-06-05 — Production-readiness orchestration (fallback team-lead-mobile)

Fallback Claude Code orchestration after the AI Office codex-exec route failed on a
legacy `ceo-mobile-ios` profile config error. Goal: execute fixable production-readiness
work, review, evaluate gaps, run a second cycle. Authoritative checkout: mac24
`/Users/andre/projects/dspeech-ios`, branch `fix/review-hardening-2026-06-03`.

## Starting state
- `scripts/release/check-release-ready.sh` FAILED on three items:
  1. fresh unsigned archive build failed,
  2. release binary string scan unreliable (sentinel literal absent),
  3. missing captured App Store screenshots.

## Cycle 1 — execution + review + gap eval

### Defect 1 — unsigned archive build (environmental, masked as code regression)
Root cause: mac24's `xcode-select` had drifted to `/Library/Developer/CommandLineTools`,
so `xcodebuild -showBuildSettings` aborted ("requires Xcode"); `build-unsigned-archive.sh`
masked the error with `2>/dev/null`, MARKETING_VERSION came back empty, and `set -e`
aborted silently.
Fix `3cd1913` — `build-unsigned-archive.sh` now resolves a full Xcode via `DEVELOPER_DIR`
(no sudo) when the active dir lacks one, and fails loudly if none exists. CI unaffected
(happy path keeps the already-selected Xcode). Closes the 2026-06-03 codex tech-lead
finding (no explicit-Xcode assertion).

### Defect 2 — release-binary sentinel scan (real gate bug: SIGPIPE + pipefail)
The probe-exclusion guard used `strings -a binary | grep -qF <sentinel>`. Under
`set -o pipefail`, `grep -q` closes the pipe on first match, `strings` dies with SIGPIPE,
and pipefail propagates the non-zero status — so a sentinel that IS present (verified: 1
hit in the binary) was reported absent, failing the gate on a CORRECT release binary.
Reproduced deterministically on mac24 (Xcode 26.4) with/without pipefail.
Fix `62a2a67` — switch to `grep -cF` (full-read; strings exits cleanly) with `|| true`
for the legitimate zero-match. No false-PASS introduced (a truly-absent sentinel still
yields 0 → still fails).

### Defect 3 — App Store screenshots
Ran the existing `scripts/screenshots/capture-app-store-screenshots.sh` (real automation:
builds the app for the simulator, boots 4 App-Store device profiles, captures the
localOnly cockpit empty state, validates exact pixel dimensions). Seeded SwiftPM checkouts
from an existing DerivedData (no-outbound). Captured 4 PNGs (iphone-67, iphone-65, ipad-13,
ipad-129) under `tmp/app-store-screenshots/2026-06-05/` (gitignored — local submission
evidence, not committed).

### Cycle-1 review verdict: APPROVE
Minimal, fail-loud, no scope drift, no secrets; both gate fixes verified by reproduction
on the real target.

## Cycle 2 — second fix pass + re-verify
Fix `6a5b02c` — `capture-app-store-screenshots.sh` self-heals the same `xcode-select`
drift (xcodebuild + simctl) so screenshot regeneration needs no manual `DEVELOPER_DIR`.
Verified end-to-end with DEVELOPER_DIR unset on a CLT-drifted host: auto-resolved Xcode,
BUILD SUCCEEDED, all 4 screenshots regenerated.

### Final verification (HEAD `6a5b02c`)
`scripts/release/check-release-ready.sh` → "Unsigned release-readiness checks passed
(fresh archive built and validated)." Only a WARNING remains: signing/ASC secret
validation skipped (op CLI unavailable / Apple-credential-gated).

## Production-readiness gap matrix

| Tier | Status | Remaining |
|---|---|---|
| Internal MVP | READY | Functional app, privacy manifest, unsigned archive validated, simulator build/test green |
| TestFlight | BLOCKED on Apple-side | Apple Developer Program active + signing certs/provisioning + ASC API key in 1Password; signed archive + upload (manual, no CI automation per runbook); physical-device evidence for live Speech/audio (Developer Mode) |
| App Store | BLOCKED on Apple-side + evidence | All TestFlight items + real ATC/WER ground-truth evidence; FluidAudio SDK production claim (ADR 0008 exists, confirm binary/privacy/allowlist); screenshots uploaded to ASC; export-compliance answers |

## Newly-surfaced gap — pre-existing flaky CI (not caused by this work)
Post-push CI verification (`gh run list`) showed the Xcode "Build and test" job
failing on a FLAKE (FLAKE_THRESHOLD=0): `AccessibilityAuditUITests
.testMainFailureState_errorBannerNotObscured` throws `performAccessibilityAudit`
error **-56 "Audit failed to complete in time"** on a COLD first iteration (74s),
then PASSES on retry (17.7s). All other CI jobs (privacy manifest, swift-format,
secret scan, offline ATC eval) pass.
- Not introduced here: this work touched only shell scripts + this doc; the same
  branch CI alternates success/failure on identical code (runs 26905407883 ✓ /
  26889782001 ✓ interleaved with failures) — classic pre-existing flake.
- Root cause (hypothesis): the recognition-failure surface keeps an element
  animating/unsettled, so the audit traversal can't complete within its internal
  deadline on a cold/slow runner; warm runs settle and pass.
- Fix direction (follow-up tester/engineer pass, must be verifiable in CI's cold
  mode — NOT a threshold raise/skip): make the failure state fully settle before
  the audit (stop the listening/recording animation once the error banner is
  shown, or gate the audit on an explicit idle condition). Do not suppress.

## User actions required (cannot be automated within guardrails)
1. Activate Apple Developer Program / App Store Connect; provision signing cert +
   profile + ASC API key, store in 1Password (`op://MyInfra-Active/dspeech-*`).
2. Run the signed-build runbook on a Mac with `op` signed in; upload via Xcode/Transporter.
3. Enable iPhone Developer Mode; capture on-device live Speech/audio/dictation +
   local-only evidence per `docs/ON-DEVICE-TEST-CHECKLIST.md`.
4. Provide ground-truth transcripts for ATC fixtures to complete real WER evidence.
5. (Optional) fix the Codex `ceo-mobile-ios` legacy profile in `~/.codex/config.toml`
   to restore the canonical AI Office route.
