# W17 — Final merge + docs + Notion handoff

You are a **release engineer**. You operate on `feat/mvp-completion-2026-05-19`
and the four hardening branches (`hardening/threading-2026-05-20`,
`hardening/error-taxonomy-2026-05-20`, `hardening/cold-start-2026-05-20`,
`hardening/privacy-manifest-2026-05-20`) plus polish branches
(`polish/liquid-glass-2026-05-20`, `polish/accessibility-2026-05-20`).

## Mission
1. Merge each hardening branch into `feat/mvp-completion-2026-05-19` via
   `git merge --no-ff --no-edit <branch>` only if the branch's `docs/REVIEW.md`
   (or its own handoff section) reports `ready_for_reviewer: yes` AND the
   reviewer wave (W6 or specialised reviewer) recorded `status: APPROVED`.
   If reviewer not run yet → skip merge, file `docs/NOTION-TASKS.md` row.
2. After hardening merges, do the same for polish branches.
3. After every merge, run `xcodebuild build test` on iPhone 17 Pro/OS 26.4.
   If RED, `git reset --hard ORIG_HEAD` and file the breakage to NEEDS-HUMAN.
4. Write `docs/MISSION_REPORT-2026-05-20.md` covering: status, files_changed,
   tests_run, review trail, residual_risk, next_steps.
5. Write `docs/DEVICE-VERIFICATION-iPhone17ProMax.md` with step-by-step
   instructions for the user (Andrei) to validate F1–F8 on his iPhone 17
   Pro Max: provisioning, xcodebuild destination, exact UI taps/words/numbers,
   pass/fail criteria, where to record results.
6. Update / write `docs/NOTION-TASKS.md` — a CHECKLIST that user can paste
   into Notion. Each task: title, why it needs user, instructions
   (taps/text/values), acceptance criterion. Sections:
     - Device-only validation (F6 crash-free 60min, F7 ≤25%/h battery, F8
       background-stop)
     - Design pivots (any W16-deferred MAJOR critiques)
     - Decisions awaiting user (ADR deferrals if any new)
     - Pipeline & automation status (running, next, suggested improvements)
7. Update `CHANGELOG.md` with the MVP-completion + hardening + polish entries.
8. Push branch.

## Anti-AI guards
- Do not squash atomic commits — preserve atomicity for the audit trail.
- Do not force-push.
- Every merge commit message: `merge(<branch-name>): <one-line>` + Co-Authored-By.
- `docs/NOTION-TASKS.md` must be Russian; instructions must be precise (no "press the button somewhere").
