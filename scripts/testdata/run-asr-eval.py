#!/usr/bin/env python3
"""Real-ASR core eval: run the REAL Dspeech engine on the controlled voice corpus and
score word error rate on its ACTUAL output (not ground-truth-through-a-gate).

For each manifest item it invokes `dspeech-replay transcribe` with the real engine
(whisperkit or apple), parses the assembled transmissions, computes ATC-normalized
token WER against the exact spoken reference, and records the displayed/filtered classification.

The pass/fail thresholds in voice-corpus.json are tuned against WhisperKit and gate both the
whisperkit and apple runs (both are on-device recognizers sharing that budget).

Categories:
  clean   — studio TTS (gates on thresholds.cleanMaxAvgWER + minClassificationAccuracy)
  radio   — VHF-AM degraded variant (gates on thresholds.radioMaxAvgWER)
  overlap — two speakers stepping on each other (reported; separation stress)

Usage:
  run-asr-eval.py --audio-dir tmp/voice-corpus [--engine whisperkit|apple]
                  [--categories clean,radio,overlap] [--manifest <json>]
"""
import argparse
import hashlib
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = REPO_ROOT / "tmp" / "asr-cache"
# why: the cached value is the FULL `transcribe` output (transcription AND classification),
# so the cache must invalidate whenever the engine/classifier/call-sign Swift changes — else a
# code change would be "verified" against stale results. Fold a hash of the ReplayKit sources
# into the cache key so any edit there busts the cache automatically.
_SRC = sorted((REPO_ROOT / "Dspeech/Tools/ReplayKit/Sources/DspeechReplayKit").glob("*.swift"))
MODULE_HASH = hashlib.sha256(b"".join(p.read_bytes() for p in _SRC)).hexdigest()[:12]
TRANSMISSION_RE = re.compile(r"\[(DISPLAYED|FILTERED)\s[^\]]*\]\s+«(.*?)»")
_NUM = {
    "zero": "0", "oh": "0", "o": "0", "one": "1", "two": "2", "three": "3", "four": "4",
    "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "niner": "9",
}


def tokenize(text: str) -> list[str]:
    # why: ATC speech is spoken as words ("two seven", "three thousand") but the ASR emits
    # numerals ("27", "3000", "118.7"). Canonicalize both sides to digit runs so WER measures
    # real recognition error, not number formatting — the same normalization the app must do
    # for call-sign / heading / frequency matching.
    raw = re.findall(r"[a-z]+|[0-9]+|\.", text.lower())
    out: list[str] = []
    numbuf = ""
    for tok in raw:
        if tok in _NUM:
            numbuf += _NUM[tok]
        elif tok == "thousand":
            numbuf += "000" if numbuf else "1000"
        elif tok == "hundred":
            numbuf += "00" if numbuf else "100"
        elif tok in ("decimal", "point", "."):
            numbuf += "."
        elif tok.isdigit():
            numbuf += tok
        else:
            if numbuf:
                out.append(numbuf)
                numbuf = ""
            out.append(tok)
    if numbuf:
        out.append(numbuf)
    return out


def wer(reference: str, hypothesis: str) -> float:
    ref, hyp = tokenize(reference), tokenize(hypothesis)
    if not ref:
        return 0.0 if not hyp else 1.0
    prev = list(range(len(hyp) + 1))
    for i in range(1, len(ref) + 1):
        cur = [i] + [0] * len(hyp)
        for j in range(1, len(hyp) + 1):
            cur[j] = prev[j - 1] if ref[i - 1] == hyp[j - 1] else min(prev[j], cur[j - 1], prev[j - 1]) + 1
        prev = cur
    return prev[len(hyp)] / len(ref)


def transcribe(audio: Path, locale: str, callsign: str, engine: str) -> tuple[str, bool, bool]:
    # why: WhisperKit/Apple output is deterministic for a given audio+engine+locale+callsign,
    # but each decode costs seconds. Cache by content hash so iterating on the DOWNSTREAM
    # classification/normalization logic does not re-run the engine on unchanged audio.
    key = hashlib.sha256(
        audio.read_bytes() + f"|{engine}|{locale}|{callsign}|{MODULE_HASH}".encode()
    ).hexdigest()[:16]
    cache_file = CACHE_DIR / f"{key}.json"
    if cache_file.exists():
        cached = json.loads(cache_file.read_text())
        return cached["text"], cached["displayed"], cached["any_block"]
    text, displayed, any_block = _transcribe_uncached(audio, locale, callsign, engine)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_file.write_text(json.dumps({"text": text, "displayed": displayed, "any_block": any_block}))
    return text, displayed, any_block


def _transcribe_uncached(
    audio: Path, locale: str, callsign: str, engine: str
) -> tuple[str, bool, bool]:
    result = subprocess.run(
        [
            "swift", "run", "--package-path", str(REPO_ROOT / "Dspeech/Tools/ReplayKit"),
            "dspeech-replay", "transcribe",
            "--audio", str(audio), "--locale", locale, "--callsign", callsign,
            "--engine", engine,
        ],
        cwd=REPO_ROOT, capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"transcribe failed for {audio.name}:\n{result.stderr}")
    texts, displayed, any_block = [], False, False
    for kind, text in TRANSMISSION_RE.findall(result.stdout):
        any_block = True
        texts.append(text)
        if kind == "DISPLAYED":
            displayed = True
    return " ".join(texts), displayed, any_block


def build_items(manifest: dict, audio_dir: Path, categories: set[str]):
    items = []  # (category, label, path, ref, expectDisplayed)
    for clip in manifest["clips"]:
        if "clean" in categories:
            items.append(("clean", clip["id"], audio_dir / f"{clip['id']}.wav",
                          clip["text"], clip["expectDisplayed"]))
        if "radio" in categories:
            items.append(("radio", f"{clip['id']}-radio", audio_dir / f"{clip['id']}-radio.wav",
                          clip["text"], clip["expectDisplayed"]))
    if "overlap" in categories:
        for o in manifest.get("overlaps", []):
            items.append(("overlap", o["id"], audio_dir / f"{o['id']}.wav",
                          o["text"], o["expectDisplayed"]))
    return items


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--audio-dir", required=True)
    ap.add_argument("--engine", default="whisperkit", choices=["whisperkit", "apple"])
    ap.add_argument("--manifest", default=str(REPO_ROOT / "scripts/testdata/voice-corpus.json"))
    ap.add_argument("--categories", default="clean,radio,overlap")
    args = ap.parse_args()

    manifest = json.loads(Path(args.manifest).read_text())
    audio_dir = Path(args.audio_dir)
    locale, callsign = manifest["locale"], manifest["callsign"]
    th = manifest["thresholds"]
    categories = {c.strip() for c in args.categories.split(",") if c.strip()}
    items = build_items(manifest, audio_dir, categories)

    print(f"engine={args.engine}  locale={locale}  callsign={callsign}  items={len(items)}\n")
    print(f"{'category':9} {'clip':32} {'WER':>6}  {'class':9} {'expect':9} transcript")
    print("-" * 124)

    stats = defaultdict(lambda: {"wer": [], "class_ok": 0, "n": 0})
    for category, label, path, ref, expect in items:
        if not path.exists():
            raise SystemExit(f"Missing audio {path} — run generate-voice-corpus.sh first")
        hyp, displayed, any_block = transcribe(path, locale, callsign, args.engine)
        score = wer(ref, hyp)
        actual = "displayed" if displayed else ("filtered" if any_block else "none")
        expect_c = "displayed" if expect else "filtered"
        ok = actual == expect_c
        s = stats[category]
        s["wer"].append(score)
        s["n"] += 1
        s["class_ok"] += 1 if ok else 0
        flag = "" if ok else "  <-- MISMATCH"
        print(f"{category:9} {label:32} {score:6.3f}  {actual:9} {expect_c:9} «{hyp}»{flag}")

    def avg(xs):
        return sum(xs) / len(xs) if xs else 0.0

    print("-" * 124)
    print("\nSUMMARY")
    failures = []
    for category in ("clean", "radio", "overlap"):
        if category not in stats:
            continue
        s = stats[category]
        a, acc = avg(s["wer"]), s["class_ok"] / s["n"]
        print(f"  {category:8} avg WER={a:.3f}  classification {s['class_ok']}/{s['n']} ({acc:.0%})")
        if category == "clean" and a > th["cleanMaxAvgWER"]:
            failures.append(f"clean WER {a:.3f} > {th['cleanMaxAvgWER']}")
        if category == "radio" and a > th["radioMaxAvgWER"]:
            failures.append(f"radio WER {a:.3f} > {th['radioMaxAvgWER']}")

    if "clean" in stats:
        acc = stats["clean"]["class_ok"] / stats["clean"]["n"]
        if acc < th["minClassificationAccuracy"]:
            failures.append(f"clean classification {acc:.0%} < {th['minClassificationAccuracy']:.0%}")

    # Per-engine gating. The thresholds in voice-corpus.json are tuned against WhisperKit (the
    # production ASR); apple shares that same on-device-recognition budget, so both engines are gated.
    #   engine      | clean WER | radio WER | clean class | gated  (thresholds from voice-corpus.json)
    #   ------------+-----------+-----------+-------------+------
    #   whisperkit  | <= 0.20   | <= 0.55   | >= 80%      | YES
    #   apple       | <= 0.20   | <= 0.55   | >= 80%      | YES
    print(
        f"\nthreshold source: WhisperKit-tuned (clean WER <= {th['cleanMaxAvgWER']}, "
        f"radio WER <= {th['radioMaxAvgWER']}, clean class >= {th['minClassificationAccuracy']:.0%})"
    )

    if failures:
        print("\nFAIL:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 2
    print("\nPASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
