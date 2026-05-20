# W15 — Polish: accessibility & HIG audit fix

You are a **senior iOS accessibility engineer**. Branch:
`polish/accessibility-2026-05-20` from `polish/liquid-glass-2026-05-20` (or
`feat/mvp-completion-2026-05-19` if liquid glass not merged yet).

## Mission
Close every gap in `docs/a11y-audit-2026-05-19.md` and ensure WCAG AA + Apple
HIG compliance on Dspeech's MVP surfaces. Outcomes a user with VoiceOver,
Dynamic Type xxLarge, Reduce Transparency, Reduce Motion, and Increase
Contrast must experience the same task flows as the baseline user.

## Pre-flight
1. Branch from prior polish branch (or feat/mvp-* if no prior).
2. Read `docs/a11y-audit-2026-05-19.md` end-to-end.
3. Baseline test = green on `iPhone 17 Pro,OS=26.4`.

## Work areas
- **VoiceOver focus order** — ContentView, SettingsSheet, FirstRunView,
  AboutView. Use `.accessibilitySortPriority` only when natural order wrong.
- **Labels (Russian)** — every interactive control has `.accessibilityLabel`
  in Russian; hint where the action is non-obvious.
- **Dynamic Type** — every Text scales; no fixed `.frame(height:)` cropping
  large dynamic-type text.
- **Reduce Transparency** — fallback paths set under W14 are tested here
  by toggling the env value (`@Environment(\.accessibilityReduceTransparency)`)
  in a snapshot test or runtime override.
- **Contrast** — measure each text-on-glass / text-on-background pair; AA = 4.5:1
  body, 3:1 large text. Document measurements.
- **Hit targets** — every interactive control ≥ 44×44pt (HIG minimum).

## Verification gates
1. `xcodebuild build test` = **PASS 88/0/0** + any new tests green.
2. New XCUITests in `DspeechUITests/AccessibilityFlowTests.swift`:
   - VoiceOver traversal order assertions via `axes` / `accessibilityElements`.
   - Dynamic Type xxxLarge — no truncation on critical labels.
   - Reduce Transparency on — control bar still readable.
3. `docs/a11y-audit-2026-05-19.md` updated with `RESOLVED` or `DEFERRED` per finding.
4. Apple Accessibility Inspector audit run (manual record in `docs/a11y-inspector-2026-05-20.md`).

## Output
- Atomic commits + push.
- `docs/handoff.md` `## W15 polish-accessibility — 2026-05-20` with:
  `findings_resolved` (count), `findings_deferred` (count, with rationale),
  `new_xcui_tests` (count), `contrast_measurements_path`, `ready_for_reviewer: yes`.
- `docs/NOTION-TASKS.md` rows for any deferred finding (user-visible only).

## Anti-AI guards
- Context7 each accessibility modifier used.
- Do not change visual design; only a11y plumbing.
- Russian labels reviewed against project glossary (no machine-translated jargon).
