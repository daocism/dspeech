# AGENTS.md — Dspeech

Multi-agent CLI / IDE assistants (Claude Code, Codex, Cursor, etc.) working in this repo MUST read `CLAUDE.md` first. That file is the source of truth.

Quick anchors:

- Plan + decisions for the current iteration: `docs/PLAN-2026-05-18.md`.
- Architecture decisions: `docs/adr/` (numbered, append-only).
- Product surfaces (pricing, positioning, sales-bot concept, hourly-package model): `docs/product/`.
- Hard product rules (local-only default, no fake cloud, no hardware buys, no App-Store/ad ops without sign-off, no billing yet, no CIS regions): `CLAUDE.md` §"Hard rules".

If those files and this one disagree, `CLAUDE.md` wins. If `CLAUDE.md` and explicit user instructions in the current session disagree, the user wins.
