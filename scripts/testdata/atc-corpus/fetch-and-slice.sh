#!/usr/bin/env bash
set -euo pipefail

# Fetch the real aviation-ATC test corpus and slice it into fixed-length chunks for the
# real-engine validation harness. The audio is NOT committed (regenerable, gitignored under
# tmp/) — only this script + the source reference live in git. ATC radio over public airwaves
# is used here solely as local test material; nothing is redistributed.
#
# Usage: fetch-and-slice.sh [output_dir] [chunk_seconds]

SOURCE_URL="https://www.youtube.com/watch?v=T1_6SyM6Cm4"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
out_dir="${1:-$repo_root/tmp/atc-corpus}"
chunk_seconds="${2:-60}"
chunks_dir="$out_dir/chunks"

command -v yt-dlp >/dev/null 2>&1 || { echo "yt-dlp required (brew install yt-dlp)" >&2; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg required" >&2; exit 1; }

mkdir -p "$chunks_dir"

# why: YouTube blocks the default android_vr client (HTTP 403) on this video; the
# web_safari/tv/ios/mweb client set resolves a downloadable HLS audio format.
if [ ! -f "$out_dir/source-16k.wav" ]; then
  echo "Downloading source audio…"
  yt-dlp -f 'bestaudio[protocol!=m3u8_native]/bestaudio/best' \
    --extractor-args "youtube:player_client=web_safari,tv,ios,mweb" \
    -x --audio-format wav --audio-quality 0 \
    -o "$out_dir/source.%(ext)s" "$SOURCE_URL"
  src="$(ls "$out_dir"/source.* 2>/dev/null | grep -v -- "-16k" | head -1)"
  ffmpeg -y -loglevel error -i "$src" -ac 1 -ar 16000 -c:a pcm_s16le "$out_dir/source-16k.wav"
fi

echo "Slicing into ${chunk_seconds}s chunks…"
rm -f "$chunks_dir"/chunk-*.wav
ffmpeg -y -loglevel error -i "$out_dir/source-16k.wav" \
  -f segment -segment_time "$chunk_seconds" -c:a pcm_s16le -ar 16000 -ac 1 \
  "$chunks_dir/chunk-%03d.wav"

# Drop a short trailing chunk (< half the chunk length): too little out-of-window real ATC to
# test the false-pilot precision property, and the eval would flag it uninformative anyway.
last="$(ls "$chunks_dir"/chunk-*.wav 2>/dev/null | tail -1)"
if [ -n "$last" ]; then
  last_dur="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$last")"
  if awk "BEGIN{exit !(${last_dur:-0} < ${chunk_seconds}/2)}"; then
    rm -f "$last"; echo "Dropped short trailing chunk $(basename "$last") (${last_dur}s)"
  fi
fi

count="$(ls "$chunks_dir"/chunk-*.wav 2>/dev/null | wc -l | tr -d ' ')"
echo "Corpus ready: $count chunks (${chunk_seconds}s, 16kHz mono) in $chunks_dir"
echo "Source: $SOURCE_URL"
