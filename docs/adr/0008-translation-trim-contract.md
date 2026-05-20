# ADR 0008 — Translation input is forwarded untrimmed; trim is a guard-only concern

- **status:** accepted
- **date:** 2026-05-20
- **authors:** tech-lead (this dispatch), independent reviewer (W6 round 3 MAJOR-5 finding)
- **supersedes:** none
- **superseded by:** none

## Context

W6 round 3 review found two `TranslationServiceProtocol` conformers pass different values to their backends:

- `LocalTranslationService.translate` (`Dspeech/Core/Translation/TranslationService.swift:158-166`): trims for the empty-input guard, forwards `text` (untrimmed) to the backend.
- `AppleTranslationService.translate` (lines 79-117, specifically lines 84-85 and 98): trims for the empty-input guard, forwards `trimmed` to `session.translate(trimmed)`.

The protocol DocC at `TranslationServiceProtocol.swift:84-98` is silent on whether the backend sees trimmed or raw text. MAJOR-5 carried across rounds 1 → 2 → 3 with zero engagement.

## Decision

**Authoritative contract**: `translate(_ text:from:to:)` forwards the input **untrimmed**. Trimming is a guard-only concern — purely to detect empty-after-trim and short-circuit to `.invalidInput("empty")` without round-tripping to the backend. Leading and trailing whitespace **must round-trip verbatim** to the backend and (subject to the backend's own behaviour) into the returned translation.

Rationale:
- Aviation transcription frequently contains intentional leading silence markers (e.g. dictated pauses transcribed as ` ` or punctuation-prefixed leaders).
- Trimming pre-translate erases the speaker's actual disfluency profile, which downstream evaluation rubrics (see `docs/eval/asr-evaluation-rubric-2026-05-20.md`) treat as signal.
- The Apple shell's pre-trim is therefore the bug, not the local-service behaviour.

## Consequences

### Positive
- Both conformers will now agree: `LocalTranslationService` already forwards untrimmed, so this is the alignment direction.
- The protocol DocC will be amended in the W4b round-4 dispatch to make the untrimmed-forward contract explicit (one-line addition to `TranslationServiceProtocol.swift:84-98`).
- The Apple shell call site `AppleTranslationService.translate` will be amended in the W4b round-4 dispatch to pass `text` (not `trimmed`) into `session.translate(...)`. The empty-guard `if trimmed.isEmpty` stays unchanged.

### Negative
- Existing call sites that relied on implicit trimming via `AppleTranslationService` will now see whitespace pass through. The W4b round-4 dispatch must grep for every call to `TranslationService.translate(...)` and verify none of them prepends/appends whitespace expecting silent removal.

### Test coverage
- Existing `TranslationServiceTests` already cover the untrimmed-forward behaviour for `LocalTranslationService` (`should_return_backend_translation_verbatim_including_unicode` and `should_translate_very_long_input_without_truncation_when_pair_installed`).
- W4b round-4 must extend `TranslationServiceTests` with one parameterized test pinning the contract: input `"  hello  "` → backend receives `"  hello  "` (not `"hello"`), for **both** conformers via a property-fronted fake.

## Out of scope
- Backend-side trimming (Apple `TranslationSession.translate` may or may not trim internally; that is Apple's contract, outside this ADR).
- Locale-aware whitespace (NBSP, ideographic-space) — covered by existing Unicode round-trip test.

## Cross-references
- W6 round-3 MAJOR-5 in `docs/REVIEW.md`
- Aviation rubric pause-handling: `docs/eval/asr-evaluation-rubric-2026-05-20.md`
- Implementation amendment scope: `Dspeech/Core/Translation/TranslationService.swift:79-117`, `TranslationServiceProtocol.swift:84-98`
