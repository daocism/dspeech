#!/usr/bin/env bash
set -euo pipefail
ROOT="${DSPEECH_WORKSPACE:-/Users/andre/projects/dspeech-ios}"
cd "$ROOT"
./scripts/dspeech-agent-env.sh --check
if [[ "${DSPEECH_AGENT_RUN_CLAUDE_SMOKE:-0}" == "1" ]]; then
  tmp="$(mktemp)"
  cat >"$tmp" <<'EOF'
You are doing a read-only smoke test for the Dspeech mac24 developer-orchestrator wrapper.
Read AGENTS.md and CLAUDE.md enough to understand the rules. Do not modify files, do not run builds, do not use network.
Return exactly one line: Dspeech orchestrator smoke OK: <one short reason>.
EOF
  if command -v timeout >/dev/null 2>&1; then
    timeout 180 ./scripts/dspeech-agent-env.sh --prompt-file "$tmp"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' 180 ./scripts/dspeech-agent-env.sh --prompt-file "$tmp"
  else
    ./scripts/dspeech-agent-env.sh --prompt-file "$tmp"
  fi
  rm -f "$tmp"
fi
