# W14 — Polish: Liquid Glass design pass (iOS 26)

You are a **senior iOS UI designer/implementer**. Branch:
`polish/liquid-glass-2026-05-20` from the **merged tip** of all hardening
branches (W10/W11/W12/W13 merged into `feat/mvp-completion-2026-05-19` by W17
docs wave). If not yet merged, base on `feat/mvp-completion-2026-05-19`.

## Mission
Apply iOS 26 Liquid Glass material to Dspeech's chrome to look premium without
sacrificing legibility or a11y. Use SwiftUI iOS 26 APIs (`.glassEffect(_:in:)`,
`GlassEffectContainer`, `.glassEffect(in:)`) where Apple documents them; never
hand-roll blur+opacity for the same surface.

## Surfaces to upgrade
1. **Control bar** (top of ContentView): "Dspeech" title block + LOCAL badge +
   gear button + Перевод toggle. Wrap in `GlassEffectContainer` so the
   morphology blends with content scroll behind.
2. **PrivacyBadge** ("LOCAL" / "CLOUD"): clear glass pill with tonal accent
   (green/local, amber/cloud). Preserve current accessibilityLabel.
3. **SettingsSheet**: sectioned rows with glass background per row group.
4. **FirstRunView**: 3 onboarding cards on a soft glass canvas.
5. **AboutView**: attribution panel as glass card.

## Required design constraints (per Apple HIG iOS 26)
- Maintain 4.5:1 contrast (WCAG AA) on all text over glass surfaces. Verify
  with `Color.contrast(against:)` helper or manual measurement on a dark scroll
  background (record screenshots).
- **Reduce Transparency** fallback: read `@Environment(\.accessibilityReduceTransparency)`
  and substitute opaque material (`Color(.systemBackground)` / equivalent).
- **Reduce Motion**: no spring-bounce on glass morph transitions when set.
- Dynamic Type: every text view supports `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)`.
- No more than **2 stacked glass layers** in any vertical compose path.
- Dark mode + light mode both verified.

## Don'ts (anti-cheap-looking)
- No drop-shadows under glass surfaces.
- No saturated colour fills on glass (defeats material).
- No animated transparency oscillation.
- No glass on body text background (only on chrome/cards).

## Verification gates
1. `xcodebuild build test` on `iPhone 17 Pro,OS=26.4` = **PASS 88/0/0**.
2. Capture 10 screenshots into `docs/screenshots/polish-2026-05-20/` —
   5 light, 5 dark, covering all 5 surfaces above. Use `xcrun simctl io booted screenshot`.
3. Capture Reduce-Transparency-on equivalents for 5 surfaces (additional 5
   screenshots into `docs/screenshots/polish-2026-05-20-reduce-transparency/`).
4. Run `xcrun xcresulttool` smoke test for accessibility audit if available;
   otherwise document manual Inspector results.
5. `grep -rn "blur(radius" Dspeech/ | grep -v PreviewProvider` → zero outside
   PreviewProvider (no hand-rolled glass).

## Output
- Atomic commits + push the polish branch.
- `docs/handoff.md` `## W14 polish-liquid-glass — 2026-05-20` with:
  `surfaces_upgraded`, `screenshots_path`, `contrast_pass`, `reduce_transparency_ok`,
  `dark_mode_ok`, `xcodebuild_test`, `ready_for_reviewer: yes`.
- `docs/DESIGN-DECISIONS-LIQUID-GLASS.md` — record the design choices (which
  surfaces, why, fallback strategy, contrast measurements).
- `docs/NOTION-TASKS.md` row "review design pass screenshots" with the
  screenshots-folder link so user can eyeball it.

## Anti-AI guards
- Context7 every iOS 26 glass API before using. Pin doc URL in commit body.
- Do not invent SwiftUI modifiers; if an API does not Context7-verify, defer it.
- Zero accessibility identifier changes (XCUITests must still pass).
