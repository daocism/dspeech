# W11 — Hardening: unified error taxonomy adoption

You are an **error-handling hardening implementer**. Branch:
`hardening/error-taxonomy-2026-05-20` cut from `feat/mvp-completion-2026-05-19`.

## Mission
Align every Core/* error type on the unified taxonomy in `docs/error-taxonomy.md`.
Eliminate ad-hoc error shapes; ensure errors carry the four contract fields:
`code`, `summary`, `cause`, `recovery`. Every boundary (ContentView `.task`,
DspeechApp scenePhase, FirstRunCoordinator entry) must funnel errors through
the same surface (typed sheet / banner / log).

## Pre-flight
1. `cd ~/projects/dspeech-ios && git checkout feat/mvp-completion-2026-05-19 && git pull --ff-only && git checkout -b hardening/error-taxonomy-2026-05-20`
2. Baseline `xcodebuild build test` on `iPhone 17 Pro,OS=26.4` = **PASS 88/0/0**.

## Work
- Map every existing error enum (`TranslationServiceError`, `AudioInputServiceError`,
  `FirstRunCoordinatorError`, etc.) onto the taxonomy.
- Add the four required fields (computed properties acceptable).
- Add a single shared `ErrorPresenter` (or extend the existing presenter) so the
  UI gets a uniform banner with: title (`summary`), body (`cause`), action
  (`recovery`). Russian copy required.
- Ensure ContentView's banner & SettingsSheet error rows use the same path.

## Verification gates
1. `xcodebuild build test` = **PASS 88/0/0** (regression). New tests for the
   taxonomy mapping go in `DspeechTests/ErrorTaxonomyMapTests.swift`.
2. `grep -rn "return nil" Dspeech/Core/ | grep -v "// why:"` → zero new offenders.
3. `grep -rn "catch {}" Dspeech/` → zero new offenders.
4. Every public throw site in Core lists its error case in the taxonomy doc.

## Output
- Atomic commits on the branch + push.
- `docs/handoff.md` append `## W11 hardening-error-taxonomy — 2026-05-20` with
  fields: `errors_unified`, `presenter_path`, `xcodebuild_test`,
  `regression_checks`, `ready_for_reviewer: yes`.
- `docs/NOTION-TASKS.md` rows for any taxonomy item deferred (with file:line).

## Anti-AI guards
- No silent catches.
- No `Bool` returns where the call has 3+ failure reasons.
- Russian-language UI strings only for `summary` / `cause` / `recovery` exposed
  to the user; OSLog content stays English with `.private` for PII.
- Context7 / Apple-API recheck for any new framework usage.
