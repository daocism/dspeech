# mac24 Dspeech developer-orchestrator environment

Status: active on `mac24` / `/Users/andre/projects/dspeech-ios`.

## Purpose

Give coding agents a safe, repeatable entrypoint for Dspeech iOS work on the Mac that actually has Xcode and Simulator access, without touching the live Mr.Dao Telegram gateway.

## Entrypoint

```bash
cd /Users/andre/projects/dspeech-ios
./scripts/dspeech-agent-env.sh --check
./scripts/dspeech-agent-env.sh --prompt Read AGENTS.md and CLAUDE.md, then propose a read-only plan.
```

For longer prompts:

```bash
./scripts/dspeech-agent-env.sh --prompt-file /tmp/dspeech-task.md
```

## Isolation

The wrapper exports:

- `DSPEECH_WORKSPACE=/Users/andre/projects/dspeech-ios`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
- `HERMES_HOME=/Users/andre/.hermes/profiles/dspeech-dev`

`HERMES_HOME` is created now even though this Mac currently uses `claude` directly. If Hermes Agent is installed later, it should use this isolated profile/home for Dspeech instead of the default Mr.Dao runtime.

## Required guardrails

- Read `AGENTS.md` and `CLAUDE.md` before changes.
- Local-only/privacy-first Dspeech defaults remain binding.
- No App Store publish, ads, outreach, cloud-default change, billing, or hardware purchase without explicit Andrei approval.
- Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for Xcode commands; do not change global `xcode-select` unless Andrei asks.
- Commit only after real evidence: specific test/build output, and screenshot when UI changed.

## Verification

Read-only wrapper check:

```bash
./scripts/dspeech-agent-smoke.sh
```

Optional paid/subscription Claude smoke (no file writes expected):

```bash
DSPEECH_AGENT_RUN_CLAUDE_SMOKE=1 ./scripts/dspeech-agent-smoke.sh
```

The smoke is intentionally opt-in because it invokes Claude Code and consumes subscription usage/token telemetry.
