#!/usr/bin/env bash
# Speaker-ID crew/dispatcher separation regression guard.
#
# Generates the labeled voice corpus (if missing) and runs the REAL FluidAudio WeSpeaker model to
# assert the same-voice vs cross-voice cosine gap still brackets the calibrated thresholds
# (SpeakerMatchConfig pilotMatch 0.72 / ATCTranscriptGate pilotSuppress 0.82). Exits non-zero if a
# FluidAudio / extraction change collapses the separation, so the thresholds get re-derived instead
# of silently mis-classifying crew vs dispatcher. Run after any change to FluidAudioSpeakerIdentifier,
# SpeakerMatcher, or the FluidAudio dependency. See Dspeech/Core/VoiceFilter/SpeakerMatcher.swift.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

corpus_dir="tmp/voice-corpus"
manifest="scripts/testdata/voice-corpus.json"

if ! ls "$corpus_dir"/*.wav >/dev/null 2>&1; then
  echo "voice corpus missing — generating (say + ffmpeg)…"
  bash scripts/testdata/generate-voice-corpus.sh "$corpus_dir"
fi

swift run --package-path Dspeech/Tools/SpeakerEval SpeakerEval calibrate "$corpus_dir" "$manifest"
