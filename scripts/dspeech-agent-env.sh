#!/usr/bin/env bash
set -euo pipefail

# Dspeech mac24 developer-orchestrator wrapper.
# Purpose: run coding/orchestration agents from the Dspeech workspace with
# stable Xcode paths and an isolated Hermes profile/home if Hermes is used later.

ROOT="${DSPEECH_WORKSPACE:-/Users/andre/projects/dspeech-ios}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export HERMES_HOME="${HERMES_HOME:-/Users/andre/.hermes/profiles/dspeech-dev}"
export DSPPEECH_AGENT_WORKSPACE="$ROOT"
export DSPEECH_AGENT_WORKSPACE="$ROOT"
mkdir -p "$HERMES_HOME"/logs "$HERMES_HOME"/sessions "$HERMES_HOME"/state "$HERMES_HOME"/skills
cd "$ROOT"

usage() {
  cat <<EOF
Usage:
  scripts/dspeech-agent-env.sh --check
  scripts/dspeech-agent-env.sh --prompt read-only prompt for claude -p
  scripts/dspeech-agent-env.sh --prompt-file /path/to/prompt.md
  scripts/dspeech-agent-env.sh -- <command> [args...]

Defaults:
  DSPEECH_WORKSPACE=/Users/andre/projects/dspeech-ios
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  HERMES_HOME=/Users/andre/.hermes/profiles/dspeech-dev
EOF
}

if [[ $# -eq 0 ]]; then usage; exit 2; fi
case "$1" in
  --check)
    echo "workspace=$ROOT"
    echo "hermes_home=$HERMES_HOME"
    echo "developer_dir=$DEVELOPER_DIR"
    git status --short --branch
    xcodebuild -version
    command -v claude >/dev/null && claude --version || true
    command -v hermes >/dev/null && hermes --version || true
    ;;
  --prompt)
    shift
    [[ $# -ge 1 ]] || { echo "missing prompt" >&2; exit 2; }
    command -v claude >/dev/null || { echo "claude CLI not found" >&2; exit 127; }
    exec claude -p "$1"
    ;;
  --prompt-file)
    shift
    [[ $# -ge 1 ]] || { echo "missing prompt file" >&2; exit 2; }
    command -v claude >/dev/null || { echo "claude CLI not found" >&2; exit 127; }
    exec claude -p "$(cat "$1")"
    ;;
  --)
    shift
    exec "$@"
    ;;
  *)
    usage; exit 2 ;;
esac
