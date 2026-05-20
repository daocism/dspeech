# ADR 0007 — Defer TranslationSessionPort host-test seam to post-MVP

- **status:** accepted (deferred)
- **date:** 2026-05-20
- **authors:** tech-lead (this dispatch), independent reviewer (W6 round 3 MAJOR-3 finding)
- **supersedes:** none
- **superseded by:** none

## Context

W6 round 3 review found that the `AppleTranslationService.translate` and `AppleTranslationLanguagePackManager.prepareLanguages` Apple-edge layers ship with an Apple `TranslationError` → domain `TranslationServiceError` mapping table and a `LanguageAvailability.Status` → `TranslationLanguageStatus` mapping table that have **no host-side test and no scheduled device-side test**. A wrong-mapping bug here would silently route a meaningful error to `.engineFailure(String(describing:))` and lose semantic precision for UI.

The structural fix would mirror the W1-architect remediation for audio: introduce a pure-Core `TranslationSessionPort` DI seam analogous to `AudioInputSessionPort`, then drive the Apple shell from a fake conformer in unit tests. Reviewer round-1 / round-2 / round-3 carried this as MAJOR-3 across three rounds with zero engagement.

## Decision

**Defer** the `TranslationSessionPort` seam introduction to a post-MVP iteration. Accept the Apple-edge mapping table as **device-only validated** for the MVP-slice ship.

The MVP-slice critical path (closing BLOCK-2 first-run / About coverage, MAJOR-4 launch-arg gate, W7 verifier 8-gate, ship) is materially more important than expanding host-test coverage of the Translation Apple-edge. The mapping tables are short, mechanical, and inspected during W6 anti-AI-failure pattern audit ("Zero hallucinated APIs across the branch") — the residual risk is bounded by Andrei's device-run pass against a finite set of error/status surfaces.

## Consequences

### Positive
- W4b round-4 dispatch can target the user-visible BLOCK-2 surface (first-run cover + About) without the round-4 cycle absorbing a parallel large structural refactor.
- The `TranslationSessionPort` seam is now an **explicit post-MVP work item** in `docs/NOTION-TASKS.md` — visible to Andrei, not lost in a reviewer escalation file.

### Negative
- The `TranslationError` → `TranslationServiceError` mapping table is one mis-wire away from silent-failure on UI semantics until the device run catches it.
- The `LanguageAvailability.Status` mapping table has the same exposure.

### Mitigation
1. `docs/NOTION-TASKS.md` carries the post-MVP work item: "introduce `TranslationSessionPort` host-test seam, mirror `AudioInputSessionPort` design (see `Dspeech/Core/Audio/AudioInputServiceProtocol.swift:243`)".
2. `docs/DEVICE-VERIFICATION-iPhone17ProMax.md` (W9 deliverable) explicitly lists "verify Translation error mapping" as a device gate Andrei must walk through before ship.
3. Reviewer's MAJOR-3 finding stays in `docs/REVIEW.md` round-3 record — institutional memory.

## Out of scope
- Modifying the Apple-edge mapping tables under this ADR. The tables stand as-shipped.
- Introducing the seam in this branch. Post-MVP only.

## Cross-references
- W6 round-3 MAJOR-3 in `docs/REVIEW.md`
- W1-architect audio seam precedent: `docs/architecture-mvp-slice-2026-05-19.md` + commit `5a6cf77`
- Post-MVP work item: `docs/NOTION-TASKS.md` → "Hardening — TranslationSessionPort seam"
