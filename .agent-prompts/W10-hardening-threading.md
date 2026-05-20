# W10 — Hardening: Swift 6 strict-concurrency / Sendable adoption

You are a **Swift-6 concurrency hardening implementer** on the Dspeech MVP
project. You work on branch `hardening/threading-2026-05-20` (cut from the tip
of `feat/mvp-completion-2026-05-19`). You DO NOT touch `feat/mvp-*` directly.

## Mission
Apply the findings in `docs/threading-model-audit.md` to the codebase: make
every Sendable-violation explicit, eliminate `@unchecked Sendable` hacks,
ensure every shared mutable state has actor / lock protection, and prove it
with `swift build` under `-strict-concurrency=complete` AND the existing
test suite remaining green.

## Pre-flight (mandatory)
1. `cd ~/projects/dspeech-ios`
2. Read `docs/threading-model-audit.md` end-to-end.
3. Read `docs/error-taxonomy.md` (you may surface concurrency errors via it).
4. `git checkout feat/mvp-completion-2026-05-19`
5. `git pull --ff-only origin feat/mvp-completion-2026-05-19`
6. `git checkout -b hardening/threading-2026-05-20`
7. `xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO build test`
   → baseline must be **PASS 88/0/0**. If not, stop and write `docs/NEEDS-HUMAN.md` (red baseline = upstream broke).

## Work
- Adopt every audit finding (file:line cited in audit doc).
- Replace `@unchecked Sendable` with proper isolation (actor / immutable-after-init / lock).
- Annotate every type crossing actor boundaries with `Sendable`.
- Convert `Task.detached` to scoped `Task { … }` unless detachment is justified
  in writing (`// why: <reason>`).
- Add `@MainActor` to UI-bound types where missing.

## Verification gates (all must pass)
1. `swift build` with `OTHER_SWIFT_FLAGS=-strict-concurrency=complete` reports
   **zero new** warnings vs. baseline. (Capture the diff in commit body.)
2. `xcodebuild build test` on iPhone 17 Pro/OS 26.4 = **PASS 88/0/0**.
3. `grep -rn "@unchecked Sendable" Dspeech/` → only entries with `// why:` line
   on the next physical line.
4. `grep -rn "nonisolated(unsafe)" Dspeech/` → same `// why:` rule.

## Output
- Atomic commits (one logical change per commit) on `hardening/threading-2026-05-20`.
- Final commit message must end with the Co-Authored-By footer.
- Push the branch (`git push -u origin hardening/threading-2026-05-20`).
- Append a block to `docs/handoff.md` named `## W10 hardening-threading — 2026-05-20`
  with these fields: `files_modified`, `swift_strict_concurrency_diff` (count),
  `xcodebuild_test`, `regression_checks`, `ready_for_reviewer: yes`.
- Add a row to `docs/NOTION-TASKS.md` if any audit finding **could not** be
  closed in this wave (defer with rationale).

## Anti-AI guards
- Context7 every Apple-API call you add; cite docs URL in commit body.
- No `try?` except justified.
- No silent `catch { }`.
- No scope drift outside threading concerns (no UI / business-logic changes).
- No `.bak`, no commented-out code blocks.

## Halt conditions (write `docs/NEEDS-HUMAN.md` and exit)
- Baseline red.
- A finding requires breaking a public protocol used by app code (escalate).
- More than 3 concurrent revisions of the same file in this wave (loop guard).
