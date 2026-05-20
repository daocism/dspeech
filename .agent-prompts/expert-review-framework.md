# Expert-level review framework — Dspeech / iOS 26 / Swift 6

Every reviewer wave **must** apply this checklist verbatim and cite file:line for
every finding. Skipping a section = the wave is invalid.

## 1 — Behavioural correctness
- Off-by-one in loops, slices, ranges, paginations.
- Empty / nil / overflow / negative / duplicate / concurrent input.
- Race conditions: any `Task { … }` that reads then writes shared state without
  actor isolation or `os_unfair_lock`.
- Stale closures: `[weak self]` missing where a long-lived `Task` / `Combine` /
  `AsyncSequence` is owned.
- Re-entrancy: actor reentrancy after `await` (state may have mutated).

## 2 — Swift 6 strict concurrency
- Every type crossing actor boundaries must be `Sendable`.
- `@MainActor` annotations on UI types; no `MainActor.assumeIsolated` to fake it.
- No `nonisolated(unsafe)` without a `// why:` line.
- No `Task.detached` without explicit reason.
- `@unchecked Sendable` requires explicit lock / immutable-after-init proof.

## 3 — Error handling (Dspeech policy)
- Internal code throws typed errors; never returns `nil`/`Bool`/`Result` for
  recoverable cases unless a caller branches on it.
- Errors propagate to **exactly one** boundary per subsystem (ContentView's
  `task`, App scenePhase, or background job entry).
- Zero `try?` outside justified cases (timer cancels, prewarm side-effects).
- Zero `catch { }` that swallows.

## 4 — SwiftUI / Combine memory
- `@StateObject` only where view owns the lifecycle. `@ObservedObject` if
  passed in.
- `.task { … }` for view-bound async work, not `.onAppear { Task { … } }`.
- No closure captures `self` strongly in `sink` / `assign` / `Timer`
  (potential retain cycle).

## 5 — Accessibility (App Store baseline)
- Every interactive control has an `accessibilityIdentifier` and an
  `accessibilityLabel` (Russian for user-visible labels per repo convention).
- Dynamic Type: text scales; no fixed-size frames around text.
- VoiceOver order: read top-to-bottom matches visual order.
- Reduce Transparency env-var honoured (`accessibilityReduceTransparency`)
  for any glass / blur / translucent material.

## 6 — Performance / responsiveness
- `body` computations: any allocation per recompute (re-allocating preparer
  chains, formatters, decoders) = MAJOR.
- `LazyVStack` / `List` for any potentially-unbounded scroll.
- Image / icon resources resolved at load time, not body.
- No `@Published` setters inside `body` (re-render loop).

## 7 — Security & privacy (ADR 0002 contract)
- `grep` `URLSession`, `URLRequest`, `Network`, `nw_`, `WebSocket` in
  `Core/Translation/` and `Core/Speech/` → must be zero unless explicit
  cloud-mode path with `PrivacySettings.cloudOptIn == true` gate.
- No PII in OSLog with public-by-default level. PII → `.private`.
- No `print(…)` of audio buffer / transcript content.
- Hard-coded credentials / tokens / API keys → CRITICAL.

## 8 — Test quality
- New tests are deterministic (no real time, no real network, no real audio,
  injected fakes).
- Property-based tests use stable seeding (`Hypothesis`-style).
- UI tests use `accessibilityIdentifier`, never label-string match (l10n fragile).
- Test names follow `should<X>_when<Y>` pattern.

## 9 — Code craft
- Names carry meaning; no `data`, `info`, `value`, `temp`, `_result`.
- Functions ≤6-word purpose, otherwise split.
- No dead code, no commented-out blocks, no `.bak` files left behind.
- No TODO / `placeholder` / `Coming soon` / `not implemented` strings.

## 10 — Anti-rubber-stamp guards
- Reviewer must run the suite themselves and cite the destination + result.
- Reviewer must Context7-recheck any Apple-API call introduced in this round.
- Reviewer must reproduce any UI XCUI failure with `simctl io screenshot` or
  exact reason it cannot.

## Severity grading
- **BLOCK** — must fix before merge: behavioural correctness, concurrency
  safety, security, accessibility identifier missing on shipping control.
- **MAJOR** — fix in same iteration or ADR-defer with explicit deferral note.
- **MINOR** — backlog item, file in `docs/NOTION-TASKS.md`.

## Output contract
Every reviewer wave writes `docs/REVIEW.md` (prepended) with:
- `## W{N} reviewer round {R} — {YYYY-MM-DD}`
- `### status: APPROVED | CHANGES_REQUESTED | ESCALATED`
- `### findings: K BLOCK + M MAJOR + N MINOR`
- bullet per finding with `file:line` and one-line rationale
- `### context7_recheck:` table of Apple-API calls verified this round
- `### test_suite:` destination + PASS/FAIL count
- `### cycle_warning:` if round R ≥ 2
