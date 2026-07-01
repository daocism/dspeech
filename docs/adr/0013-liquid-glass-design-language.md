# ADR 0013 — iOS 26 Liquid Glass design language on chrome surfaces

Date: 2026-07-02
Status: accepted (landing on `feat/night-polish-20260702` per `docs/PLAN-2026-07-02-night-polish.md`, phase D)
Relates: ADR 0002 (privacy badge always visible/truthful), CLAUDE.md hard rule #4, `~/.claude/rules/common/ui-quality.md` gate, 2026-07-02 five-agent audit (UI/UX report: zero material/glass usage despite iOS 26 target)

## Context

The app targets iOS 26.0+ and builds with Xcode 26, but the entire UI is hand-rolled flat
SwiftUI: `color.opacity(n)` fills with stroke overlays, no materials, no vibrancy. System
chrome (sheets, alerts, menus) already renders Liquid Glass on iOS 26, so the app's own
floating chrome — control bar, Start/Stop button, status chips, banners, hint bubbles —
reads as visually one generation older than the OS it ships on. Apple's HIG names
"floating controls over dynamic content" as the canonical Liquid Glass use case; our
control chrome floats over a continuously scrolling live transcript.

## Decision

1. **Adopt native Liquid Glass APIs** (`glassEffect`, `GlassEffectContainer`,
   `glassEffectID`, glass button styles) on the **chrome layer only**:
   control bar, Start/Stop button, privacy/route chips, floating Clear control,
   status banners, hint bubbles, filtered-count pill.
2. **Never on scrolling content.** Transcript cards keep opaque fills — glass belongs to
   the layer floating above the transcript, not to the transcript itself (legibility of
   ATC text is the product; GPU cost of per-card backdrops is unjustifiable).
3. **`.regular` variant everywhere** glass sits above the live transcript. `.clear` is
   reserved for media-rich backgrounds we do not have; text-bearing controls over
   variable content require the adaptive contrast of `.regular`.
4. **One `GlassEffectContainer` per cluster.** Every independent glass effect costs a
   `CABackdropLayer` (~3 offscreen render textures). Clustered elements (control bar,
   badge row, bottom controls) share a container so they merge into one render pass.
5. **Semantic tint only through `DspeechTheme`** (introduced same phase): accent for the
   primary action, warning/danger for states. No per-view literals on glass surfaces.
6. **Accessibility guarantees are part of the definition of done**:
   - Reduce Transparency → system degrades glass to solid; the LOCAL/CLOUD privacy badge
     must remain legible in BOTH modes (hard rule #4 — verified per change, not assumed).
   - Reduce Motion → glass morph transitions disabled (system behavior; decorative
     motion additionally gated by the existing `DecorativeMotion` mechanism).
   - Increase Contrast respected; the existing a11y audit sweep
     (`AccessibilityAuditUITests`) stays the enforcement gate and gains
     Reduce-Transparency coverage.
7. **Haptics accompany the glass pass** (`sensoryFeedback`): impact on Start/Stop state
   change, success on model-pack install and enrollment completion — state-triggered,
   never tap-triggered, so failures don't emit success haptics.

## Consequences

- The app chrome matches iOS 26 system chrome; no third-party UI dependency is added —
  everything is first-party SwiftUI (per audit: OSS glassmorphism packages are either
  stale or superseded by the native APIs on our deployment target).
- GPU/energy cost is bounded by rules 2 and 4 (chrome-only, container-merged). Field
  reports put unbounded glass at ~13% battery vs ~1% for restrained usage; our surface
  count is a single-digit number of merged clusters.
- Dark-locked cockpit design is unchanged; glass adapts to the dark scheme natively.
- `UIDesignRequiresCompatibility` opt-out is NOT used (Apple removes it in Xcode 27;
  adopting now avoids a forced migration later).

## Non-decisions

- Light-mode support remains out of scope (deliberate cockpit design, unchanged).
- Transcript card styling beyond entrance transitions stays opaque; any future
  glass-on-content experiment needs its own ADR with energy measurements.
