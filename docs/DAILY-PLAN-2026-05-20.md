# Dspeech — Daily Plan 2026-05-20 (tech-lead view, v2)

> Заменяет предыдущую версию. Расширена под полноценный «рабочий день нейросетей»:
> критический путь + хардненинг + polish + финал.

## Status snapshot (2026-05-20 → tech-lead snapshot)
- **Branch**: `feat/mvp-completion-2026-05-19` pushed to `origin`.
- **HEAD**: `87bd3a5 docs(plan): daily plan 2026-05-20`
- **Resolved**: W6 BLOCK-1 (controlBar layout fix `02ca017`), MAJOR-4 prep,
  ADR-0007/0008 deferrals for MAJOR-3/5, W4b BLOCK-2 test files landed (`5b624dd`)
- **In flight**: W4b-round4 impl (closes 9 RED XCUI + MAJOR-4 + ADR-0008 amend)
- **Then**: W7 → W8 → W9 → 4× hardening || → 3× polish → W17 final

## Pipeline architecture (workday-pilot-v2.sh, 5 phases)
- **P1 critical path** (sequential): W4b-round4 → W7-verifier → W8-design → W9-docs
- **P2 hardening** (parallel × 4 `claude -p`): W10 threading || W11 errors || W12 cold-start || W13 privacy-manifest
- **P4 polish** (sequential): W14 liquid-glass → W15 accessibility → W16 gemini-iteration
- **P5 finalisation** (sequential): W17 merge + MISSION_REPORT + DEVICE-VERIFICATION + NOTION-TASKS + push

## Guard rails (anti-AI-failure)
- Rate-limit-aware sleep (parse `resets HH:MM`, no respawn loop)
- Per-wave **progress gate** — wave fails if its branch did not advance
- `docs/NEEDS-HUMAN.md` = single termination signal
- **Expert review framework** (`.agent-prompts/expert-review-framework.md`) is
  mandatory reading for every reviewer wave — Sendable / errors / a11y /
  perf / security / tests / anti-rubber-stamp
- Codex fallback wired (gpt-5.4) when Codex CLI installed on mac24

## What you (Andrei) do today
**Once**, from **macOS Terminal.app** (GUI, not via SSH):
```
cd ~/projects/dspeech-ios
nohup bash .agent-prompts/workday-pilot-v2.sh > /tmp/pilot-v2.log 2>&1 &
disown
```
That's it. Walk away. Pilot drives all 5 phases through the day.

## When you return — where to look
- `docs/MISSION_REPORT-2026-05-20.md` → final report (success path)
- `docs/NEEDS-HUMAN.md` → exists only if pilot escalated
- `docs/NOTION-TASKS.md` → tasks for your Notion (device F6/F7/F8, design
  pivots, pipeline status)
- `docs/AUTOPILOT-JOURNAL.md` → full journal of every wave

## Branches you'll see after a successful day
- `feat/mvp-completion-2026-05-19` (critical path landed, then hardening +
  polish merged in by W17)
- `hardening/threading-2026-05-20`
- `hardening/error-taxonomy-2026-05-20`
- `hardening/cold-start-2026-05-20`
- `hardening/privacy-manifest-2026-05-20`
- `polish/liquid-glass-2026-05-20`
- `polish/accessibility-2026-05-20`

## Residual risks (acknowledged, not hidden)
- iOS 26 Liquid Glass API surface is new — every modifier Context7-verified
  per W14 prompt. If a glass-API call cannot be verified, W14 defers it.
- F3 Translation kept visible (no ADR-0007 deferral) — confirmed by W5/W7.
- F6/F7/F8 device-only; instructions land in `NOTION-TASKS.md` for you.

## What I (tech-lead) develop next
- Codex CLI install on mac24 (needs `brew` from you — see NOTION-TASKS).
- Per-hardening-branch reviewer pass before W17 merge (currently W17 does the
  consolidation check — fine for MVP, splittable later).
- GitHub Actions self-hosted runner on mac24 (mirror local pipeline to CI).
- Snapshot-test suite (design exists at `docs/snapshot-tests-design.md`).

— tech-lead, autopilot
