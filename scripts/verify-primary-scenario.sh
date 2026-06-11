#!/usr/bin/env bash
# Mechanical definition-of-done gate (SPEC-2026-06-12 §4.3).
# Runs both owner-provided French ATC fixtures through the REAL ASR pipeline
# (macOS on-device SFSpeechRecognizer) + REAL TransmissionAssembler + classifier
# and prints the blocks exactly as the UI would group them. Local gate only —
# never wired into hosted CI (macOS runner minutes).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPLAYKIT_DIR="$REPO_ROOT/Dspeech/Tools/ReplayKit"
FIXTURES_DIR="$REPO_ROOT/DspeechTests/Fixtures/ATC"
ENGINES=("${DSPEECH_ENGINES:-apple}")
LOCALE="${DSPEECH_LOCALE:-fr-FR}"
CALLSIGN="${DSPEECH_CALLSIGN:-}"
GAP="${DSPEECH_GAP:-3.5}"

cd "$REPLAYKIT_DIR"
swift build --quiet

status=0
for engine in "${ENGINES[@]}"; do
  for wav in "$FIXTURES_DIR"/*.wav; do
    echo "════════════════════════════════════════════════════════════════"
    echo "FIXTURE: $(basename "$wav")  engine=$engine locale=$LOCALE gap=$GAP callsign=${CALLSIGN:-<none>}"
    echo "────────────────────────────────────────────────────────────────"
    args=(transcribe --audio "$wav" --locale "$LOCALE" --engine "$engine" --gap "$GAP")
    if [[ -n "$CALLSIGN" ]]; then args+=(--callsign "$CALLSIGN"); fi
    if ! swift run --quiet dspeech-replay "${args[@]}"; then
      echo "FIXTURE FAILED: $(basename "$wav") engine=$engine" >&2
      status=1
    fi
  done
done
exit "$status"
