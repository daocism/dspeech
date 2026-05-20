# W16 — Polish: Gemini design iteration loop

You are a **design QA orchestrator**. Branch: stay on
`polish/accessibility-2026-05-20` (or whichever polish branch ended W15).
You DO NOT cut a new branch unless Gemini surfaces a code change.

## Mission
Send each of the 10 polish screenshots (`docs/screenshots/polish-2026-05-20/`)
to Gemini 3.1 Pro via MCP for expert design review. Capture findings, classify,
and either fix them in-place (small visual tweaks: padding, alignment, copy)
or file them as NOTION tasks (larger design pivots that need user judgment).

## Pre-flight
1. Verify Gemini MCP is reachable (test ping). If unavailable, write
   `docs/NEEDS-HUMAN.md` "Gemini MCP unreachable" and exit.

## Work loop (per screenshot)
1. Send screenshot + this expert prompt to Gemini 3.1 Pro:
   > "Senior iOS app designer review. App is Dspeech, iPhone 17 Pro Max, iOS 26,
   > Liquid Glass material. Critique on: contrast, hierarchy, alignment, padding
   > consistency, glass overuse, copy clarity (Russian), missing affordances.
   > Output: 3 strongest critiques with `severity: minor|moderate|major` and a
   > concrete `fix:` recommendation each. No fluff."
2. Parse the 3 critiques. For each:
   - `minor` (padding/alignment) → apply directly with SwiftUI tweak.
   - `moderate` → apply if mechanical; otherwise file as NOTION task.
   - `major` (design pivot) → file as NOTION task with screenshot link.

## Verification gates
1. After all in-place tweaks: `xcodebuild build test` = **PASS** (no regressions).
2. Re-screenshot affected surfaces; replace in `docs/screenshots/polish-2026-05-20/`.
3. `docs/GEMINI-REVIEW-2026-05-20.md` written with one section per surface:
   surface name, original screenshot path, 3 critiques, action taken
   (in-place fix / NOTION task / declined-with-reason).
4. `docs/NOTION-TASKS.md` updated.

## Output
- Atomic commit per surface (if code changed) + push.
- `docs/handoff.md` `## W16 gemini-iteration — 2026-05-20` with:
  `surfaces_reviewed`, `critiques_total`, `inplace_fixes`, `notion_tasks_filed`,
  `xcodebuild_test`, `ready_for_reviewer: yes`.

## Anti-AI guards
- Do not blindly apply every Gemini suggestion. Veto if it contradicts:
  - WCAG AA contrast (W15 work).
  - Existing accessibilityIdentifier contracts.
  - ADR 0002 (privacy / local-only).
- Cap in-place fixes at 12 per surface to avoid loop. Excess goes to NOTION.
- Context7 any new SwiftUI API used.
