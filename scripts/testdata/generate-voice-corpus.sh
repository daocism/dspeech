#!/usr/bin/env bash
set -euo pipefail

# Materialize the controlled real-audio core-test corpus from voice-corpus.json.
#  - clean clips:   macOS `say` (distinct voices) -> 16kHz mono Int16 PCM WAV (engine format)
#  - radio clips:   ffmpeg VHF-AM degradation (300-2800Hz band-pass + white noise + compression)
#  - overlap clips: ffmpeg mix of two speakers with a time offset (step-on / separation test)
# Audio is reproducible from this script + the manifest, so WAVs are NOT committed.
#
# Usage: generate-voice-corpus.sh [output_dir]   (default: tmp/voice-corpus)

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="$repo_root/scripts/testdata/voice-corpus.json"
out_dir="${1:-$repo_root/tmp/voice-corpus}"

for tool in say afconvert ffmpeg; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required" >&2; exit 1; }
done
[ -f "$manifest" ] || { echo "Missing manifest: $manifest" >&2; exit 1; }

mkdir -p "$out_dir"
tmp_aiff="$(mktemp -t voice-corpus).aiff"
clips_tsv="$(mktemp -t voice-corpus-clips)"
overlaps_tsv="$(mktemp -t voice-corpus-overlaps)"
trap 'rm -f "$tmp_aiff" "$clips_tsv" "$overlaps_tsv"' EXIT

radioize() {
  # $1 = clean wav in, $2 = radio wav out
  ffmpeg -y -loglevel error -i "$1" \
    -f lavfi -i "anoisesrc=color=white:sample_rate=16000:amplitude=0.02" \
    -filter_complex \
    "[0:a]highpass=f=300,lowpass=f=2800,acompressor=threshold=-18dB:ratio=4:makeup=8[v];[v][1:a]amix=inputs=2:duration=first:weights=1 0.4,alimiter=limit=0.9[m]" \
    -map "[m]" -ac 1 -ar 16000 -c:a pcm_s16le "$2"
}

/usr/bin/python3 - "$manifest" > "$clips_tsv" <<'PY'
import json, sys
for clip in json.load(open(sys.argv[1]))["clips"]:
    print(clip["id"], clip["voice"], clip["text"], sep="\t")
PY

/usr/bin/python3 - "$manifest" > "$overlaps_tsv" <<'PY'
import json, sys
for o in json.load(open(sys.argv[1])).get("overlaps", []):
    print(o["id"], o["primary"], o["secondary"], o["offsetSeconds"], sep="\t")
PY

clean=0
while IFS=$'\t' read -r id voice text; do
  [ -z "$id" ] && continue
  say -v "$voice" -o "$tmp_aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp_aiff" "$out_dir/$id.wav"
  radioize "$out_dir/$id.wav" "$out_dir/$id-radio.wav"
  echo "  clip   $id.wav (+radio)  [$voice]  \"$text\""
  clean=$((clean + 1))
done < "$clips_tsv"

overlaps=0
while IFS=$'\t' read -r id primary secondary offset; do
  [ -z "$id" ] && continue
  delay_ms="$(/usr/bin/python3 -c "print(int(float('$offset') * 1000))")"
  ffmpeg -y -loglevel error -i "$out_dir/$primary.wav" -i "$out_dir/$secondary.wav" \
    -filter_complex \
    "[1:a]adelay=${delay_ms}|${delay_ms}[d];[0:a][d]amix=inputs=2:duration=longest:weights=1 0.8,alimiter=limit=0.95[m]" \
    -map "[m]" -ac 1 -ar 16000 -c:a pcm_s16le "$out_dir/$id.wav"
  echo "  overlap $id.wav  [$primary + $secondary @ ${offset}s]"
  overlaps=$((overlaps + 1))
done < "$overlaps_tsv"

echo "Voice corpus written to $out_dir ($clean clips x2 clean+radio, $overlaps overlaps)"
