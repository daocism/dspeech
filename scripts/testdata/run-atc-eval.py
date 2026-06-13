#!/usr/bin/env python3
"""Real-ATC validation harness — runs the REAL engines (WhisperKit transcription +
FluidAudio voice separation via the app's own shipping classify path) over real aviation
ATC radio chunks, with AUTHORED ground truth (splice injection) so nothing is graded by
FluidAudio against itself. Costyl-free per the design+critique panel and its adversarial pass.

SELECTION is a pure function of a seed: shuffle(seed, sorted chunk ids)[:count]. Auto-seed
walks 0,1,2,… (each integer = one reproducible cohort; full coverage by enumeration). `--seed S`
replays that cohort; reproducibility holds only for a FIXED corpus, so each run records a
corpus fingerprint (sha256 over id:bytes) and a `--seed S` replay ABORTS if the local corpus
drifted from the recorded fingerprint (rather than silently grading different audio). The
"sorted chunk ids" set — not a hardcoded count — defines the population; re-slicing the corpus
with different parameters is a different population and is caught by the fingerprint on replay.

VOICE SEPARATION runs the SHIPPING decision (vendored via symlink → Core/VoiceFilter, same
bytes the app compiles): a known operator voice (clean clip A) is ENROLLED; a DIFFERENT
degraded utterance of the SAME voice (clip B) is mixed into the real chunk, pilot-dominant,
into the chunk's QUIETEST gap (models the operator keying their own clean mic during a lull —
so the positive probe is the operator's voice, not an overlap-with-controller blend). Both
clips are macOS `say` (Samantha) TTS — see the DISCLOSURE the run prints: the positive probe
therefore tests the pipeline+threshold on a known clean-vs-radio voice pair, NOT real-human
enrolment; the false-pilot guard, by contrast, runs against REAL human ATC voices.

  HARD GATES (non-zero exit on fail):
    - void controls: own→pilot, silence→insufficientSpeech, loud 440Hz tone (clears minQuality,
      so it genuinely reaches the comparator)→NOT pilot. A constant/short-circuited matcher
      cannot satisfy all three; any wrong answer VOIDS the run.
    - comparator-reached floor: the false-pilot guard is only meaningful if real-ATC segments
      actually reach the cosine comparator (decision ∈ {pilot,nonPilot,mixed}, i.e. cleared the
      minQuality gate). The cohort must reach it on enough out-of-window real segments, else the
      guard is vacuous and the run FAILS as uninformative.
    - false-pilot guard (PRIMARY safety): ZERO out-of-window real-ATC segments classified pilot
      — never suppress a controller. Asserted only over comparator-reached segments.
  DIAGNOSTIC (reported, NEVER gates — no real-ATC ground truth):
    - in-situ recall: did the injected operator voice get classified pilot in its quiet window
      (midpoint-in-window, not any-overlap). Reported with a target, never a pass condition,
      because real continuous ATC can still overlap even the quietest gap.
    - per-segment RMS quality distribution (the fail-open reality), comparator-reached counts,
      WhisperKit transcription text + median confidence (regression/plausibility only; there is
      no transcript ground truth on real ATC, so this is never WER and never a gate).

Usage:  run-atc-eval.py [--seed N] [--chunks id,id,...] [--count 5]
"""
import argparse
import array
import hashlib
import json
import math
import re
import subprocess
import sys
import wave
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CORPUS = REPO / "tmp" / "atc-corpus" / "chunks"
WORK = REPO / "tmp" / "atc-corpus"
RUNLOG = REPO / "scripts" / "testdata" / "atc-runs.log.jsonl"  # append-only LOG, never an input
ENROLL_CLIP = REPO / "tmp" / "voice-corpus" / "pilot-readback-clearance.wav"  # clean operator (A)
INJECT_CLIP = REPO / "tmp" / "voice-corpus" / "pilot-mayday-radio.wav"  # degraded, same voice (B)
TRANSMISSION_RE = re.compile(r"\[(DISPLAYED|FILTERED)\s[^\]]*\]\s+«(.*?)»")
CONF_RE = re.compile(r"conf=([0-9.]+)")
SAMPLE_RATE = 16000
COMPARATOR_DECISIONS = {"pilot", "nonPilot", "mixed"}  # reached the cosine comparator
MIN_COHORT_COMPARATOR_REACHED = 5  # else the false-pilot guard proves nothing


def sh(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()[:16]


def chunk_ids() -> list[str]:
    return sorted(p.stem for p in CORPUS.glob("chunk-*.wav"))


def corpus_fingerprint(ids: list[str]) -> str:
    h = hashlib.sha256()
    for cid in sorted(ids):
        h.update(f"{cid}:{sha256(CORPUS / (cid + '.wav'))}".encode())
    return h.hexdigest()[:16]


def select(seed: int, count: int) -> list[str]:
    import random
    ids = chunk_ids()
    shuffled = ids[:]
    random.Random(seed).shuffle(shuffled)
    return shuffled[:count]


def read_int16_mono(path: Path) -> array.array:
    with wave.open(str(path), "rb") as w:
        frames = w.readframes(w.getnframes())
        samples = array.array("h")
        samples.frombytes(frames)
        if w.getnchannels() > 1:  # average to mono
            ch = w.getnchannels()
            samples = array.array("h", (sum(samples[i:i + ch]) // ch
                                        for i in range(0, len(samples), ch)))
    return samples


def quietest_window(chunk: Path, dur: float) -> float:
    """Deterministic: the lowest-RMS dur-second window (a gap between transmissions), so the
    injected operator voice dominates its window — a clean positive probe, not an overlap blend."""
    s = read_int16_mono(chunk)
    total = len(s) / SAMPLE_RATE
    win = int(dur * SAMPLE_RATE)
    hop = int(0.25 * SAMPLE_RATE)
    lo, hi = int(3 * SAMPLE_RATE), len(s) - win - int(3 * SAMPLE_RATE)
    if hi <= lo:
        return round(max(0.0, (total - dur) / 2), 2)
    best_t, best_rms = 0.0, math.inf
    for start in range(lo, hi, hop):
        seg = s[start:start + win]
        rms = math.sqrt(sum((v / 32768.0) ** 2 for v in seg) / len(seg))
        if rms < best_rms:
            best_rms, best_t = rms, start / SAMPLE_RATE
    return round(best_t, 2)


def media_seconds(path: Path) -> float:
    r = sh(["ffprobe", "-v", "error", "-show_entries", "format=duration",
            "-of", "default=nw=1:nk=1", str(path)])
    return float(r.stdout.strip() or 0)


def inject(chunk: Path) -> tuple[Path, float, float]:
    """Mix the degraded operator clip pilot-dominant into the chunk's quietest gap (logged).
    The window is content-determined (the quietest gap), so the injected file is identical across
    runs/seeds and is named by the chunk stem alone — no seed/idx in the name (would falsely imply
    seed-varied placement and could collide cross-host with different bytes)."""
    dur = media_seconds(INJECT_CLIP)
    if dur <= 0:  # fail-loud with the real root cause, not a downstream ZeroDivisionError
        raise SystemExit(f"could not read duration of {INJECT_CLIP} — check ffprobe/ffmpeg")
    t0 = quietest_window(chunk, dur)
    t1 = round(t0 + dur, 2)
    out = WORK / f"{chunk.stem}+pilot.wav"
    ms = int(t0 * 1000)
    # why: operator's own voice reaches their own device clean+dominant (the enrolled signal);
    # received ATC outside the window stays at full level (normalize=0 → un-attenuated) so it
    # remains the realistic false-pilot test material; alimiter guards the in-window sum.
    sh(["ffmpeg", "-y", "-loglevel", "error", "-i", str(chunk), "-i", str(INJECT_CLIP),
        "-filter_complex",
        f"[1:a]adelay={ms}|{ms}[d];[0:a][d]amix=inputs=2:duration=first:weights=1 1.6:normalize=0,"
        "alimiter=limit=0.97[m]",
        "-map", "[m]", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(out)])
    return out, t0, t1


def run_gate(injected: Path, t0: float, t1: float) -> dict:
    r = sh(["swift", "run", "--package-path", str(REPO / "Dspeech/Tools/SpeakerEval"),
            "SpeakerEval", "gate", str(ENROLL_CLIP), str(injected), str(t0), str(t1)])
    for line in reversed(r.stdout.splitlines()):
        if line.startswith("{"):
            return json.loads(line)
    raise RuntimeError(f"gate produced no JSON (returncode {r.returncode}):\n{r.stderr[-2000:]}")


def run_transcribe(chunk: Path) -> dict:
    r = sh(["swift", "run", "--package-path", str(REPO / "Dspeech/Tools/ReplayKit"),
            "dspeech-replay", "transcribe", "--audio", str(chunk),
            "--locale", "en", "--engine", "whisperkit"])
    if r.returncode != 0:  # fail-loud: never let a transcription crash read as "0 words"
        return {"error": f"transcribe exit {r.returncode}", "stderr": r.stderr.strip()[-300:],
                "transmissions": None, "medianConf": None, "wordCount": None}
    confs = sorted(float(x) for x in CONF_RE.findall(r.stdout))
    texts = [t for _, t in TRANSMISSION_RE.findall(r.stdout)]
    median = confs[len(confs) // 2] if confs else 0.0
    return {"transmissions": len(texts), "medianConf": round(median, 3),
            "wordCount": sum(len(t.split()) for t in texts)}


def evaluate_chunk(cid: str) -> dict:
    chunk = CORPUS / f"{cid}.wav"
    injected, t0, t1 = inject(chunk)
    gate = run_gate(injected, t0, t1)
    segs = gate.get("segments", [])
    vc = gate.get("voidControls", {})
    # Finding 4: midpoint-in-window, not any-overlap — a wide diarized segment that merely
    # clips the window does not count as detecting the injected operator.
    for s in segs:
        mid = (s["start"] + s["end"]) / 2
        s["midInWindow"] = t0 <= mid <= t1
    in_win = [s for s in segs if s["midInWindow"]]
    out_win = [s for s in segs if not s["midInWindow"]]
    out_reached = [s for s in out_win if s["decision"] in COMPARATOR_DECISIONS]
    void_ok = (vc.get("ownEmbedding") == "pilot" and vc.get("silence") == "insufficientSpeech"
               and vc.get("loudNonVoice") != "pilot")
    false_pilots = [s for s in out_reached if s["decision"] == "pilot"]
    recall = any(s["decision"] == "pilot" for s in in_win)  # DIAGNOSTIC only
    quals = [s["appQuality"] for s in segs]
    return {
        "chunk": cid, "sha": sha256(chunk), "injectWindow": [t0, t1],
        "voidControls": vc, "voidPass": void_ok,
        "outWindowReached": len(out_reached), "outWindowTotal": len(out_win),
        "falsePilotCount": len(false_pilots), "falsePilotGuardPass": len(false_pilots) == 0,
        "inWindowRecall": recall, "enrollQuality": gate.get("enrollQuality"),
        "segments": len(segs), "insufficientSpeech": sum(1 for s in segs
                                                         if s["decision"] == "insufficientSpeech"),
        "qualityMin": round(min(quals), 3) if quals else None,
        "qualityMax": round(max(quals), 3) if quals else None,
        "outWindowScoreMax": round(max((s["score"] for s in out_reached), default=0), 3),
        "transcription": run_transcribe(chunk),
    }


def replay_guard(seed: int, fingerprint: str) -> None:
    if not RUNLOG.exists():
        return
    for line in RUNLOG.read_text().splitlines():
        if not line.strip():
            continue
        rec = json.loads(line)
        if rec.get("seed") == seed and rec.get("corpusFingerprint") not in (None, fingerprint):
            raise SystemExit(
                f"corpus drift: seed {seed} was recorded against corpus {rec['corpusFingerprint']} "
                f"but the local corpus is {fingerprint}. Re-slice produced different audio; the "
                f"replay would grade a different cohort. Aborting (delete {RUNLOG.name} to reset).")


def next_seed() -> int:
    if not RUNLOG.exists():
        return 0
    seeds = [json.loads(x)["seed"] for x in RUNLOG.read_text().splitlines() if x.strip()]
    return (max(seeds) + 1) if seeds else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--chunks", type=str, default=None)
    ap.add_argument("--count", type=int, default=5)
    args = ap.parse_args()

    for clip in (ENROLL_CLIP, INJECT_CLIP):
        if not clip.exists():
            raise SystemExit(f"missing voice clip {clip} — run generate-voice-corpus.sh")
    ids = chunk_ids()
    if not ids:
        raise SystemExit("no chunks — run scripts/testdata/atc-corpus/fetch-and-slice.sh")

    fingerprint = corpus_fingerprint(ids)
    seed = args.seed if args.seed is not None else next_seed()
    if args.seed is not None:
        replay_guard(seed, fingerprint)
    selected = args.chunks.split(",") if args.chunks else select(seed, args.count)
    missing = [c for c in selected if not (CORPUS / f"{c}.wav").exists()]
    if missing:
        raise SystemExit(f"requested chunks not in corpus: {missing}")
    print(f"seed={seed}  corpus={len(ids)} chunks fp={fingerprint}  cohort={selected}")
    print("running REAL engines (WhisperKit + FluidAudio) per chunk — this is slow…\n")

    results = [evaluate_chunk(cid) for cid in selected]

    void_fail = [r for r in results if not r["voidPass"]]
    voided = bool(void_fail)
    cohort_reached = sum(r["outWindowReached"] for r in results)
    # per-chunk floor closes the short-/silent-chunk vacuity: a chunk with 0 out-window segments
    # reaching the comparator cannot test the false-pilot property, so its trivial PASS is void.
    uninformative = [r["chunk"] for r in results if r["outWindowReached"] == 0]
    reached_floor_ok = cohort_reached >= MIN_COHORT_COMPARATOR_REACHED and not uninformative
    false_pilot_fail = [r for r in results if not r["falsePilotGuardPass"]]
    recall_hits = sum(1 for r in results if r["inWindowRecall"])

    print("=" * 78)
    print(f"REAL-ATC VALIDATION  seed={seed}  chunks={len(results)}")
    print("-" * 78)
    print("HARD GATES (non-zero exit on fail):")
    print(f"  void controls        : {'VOID RUN' if voided else 'PASS'} ({len(void_fail)} bad)")
    print(f"  comparator-reached   : {'PASS' if reached_floor_ok else 'FAIL (vacuous)'} "
          f"({cohort_reached} out-of-window real segments reached the cosine comparator, "
          f"cohort floor {MIN_COHORT_COMPARATOR_REACHED}, every chunk ≥1"
          + (f"; UNINFORMATIVE: {uninformative}" if uninformative else "") + ")")
    print(f"  false-pilot guard    : {'FAIL' if false_pilot_fail else 'PASS'} "
          f"({len(false_pilot_fail)} chunks wrongly suppressed a real controller)")
    print("\nDIAGNOSTIC (reported, never gates — no real-ATC ground truth):")
    print(f"  in-situ recall       : {recall_hits}/{len(results)} chunks detected the injected "
          f"operator in its quiet window (target ≥{ -(-len(results)//2) }; not a pass condition)")
    for r in results:
        tx = r["transcription"]
        txs = (f"ERROR {tx['error']}" if tx.get("error")
               else f"{tx['transmissions']} transmissions, medConf={tx['medianConf']}, "
                    f"{tx['wordCount']} words")
        print(f"  {r['chunk']}: segs={r['segments']} reached={r['outWindowReached']}/"
              f"{r['outWindowTotal']} insuffSpeech={r['insufficientSpeech']} "
              f"qual[{r['qualityMin']},{r['qualityMax']}] outScoreMax={r['outWindowScoreMax']} "
              f"recall={'Y' if r['inWindowRecall'] else 'n'} | tx: {txs}")
    print("-" * 78)
    print("DISCLOSURE: enroll+inject clips are macOS Samantha TTS (clean vs radio-degraded), so "
          "in-situ recall probes the pipeline+threshold on a KNOWN voice pair, not real-human "
          "enrolment. The false-pilot guard runs against REAL human ATC voices. Transcription has "
          "NO ground-truth WER here (regression/plausibility only). Voice-separation truth is the "
          "AUTHORED injection window + void controls, never FluidAudio's own labels. "
          "insufficientSpeech = app FAILING OPEN on degraded audio (shown), reported, not a win.")

    record = {"seed": seed, "utc": datetime.now(timezone.utc).isoformat(),
              "corpusFingerprint": fingerprint, "cohort": selected, "voided": voided,
              "reachedFloorOk": reached_floor_ok, "cohortReached": cohort_reached,
              "falsePilotFail": [r["chunk"] for r in false_pilot_fail],
              "recallHits": recall_hits, "results": results}
    RUNLOG.parent.mkdir(parents=True, exist_ok=True)
    with RUNLOG.open("a") as fh:
        fh.write(json.dumps(record) + "\n")
    print(f"\nappended run record (seed {seed}) to {RUNLOG.relative_to(REPO)}")

    if voided:
        print("\nRUN VOIDED: a void control failed — the matcher is short-circuited/broken.",
              file=sys.stderr)
        return 3
    if not reached_floor_ok:
        why = (f"chunks with 0 comparator-reached segments: {uninformative}" if uninformative
               else f"cohort total {cohort_reached} < floor {MIN_COHORT_COMPARATOR_REACHED}")
        print(f"\nFAIL: false-pilot guard would be vacuous ({why}) — too little real ATC reached "
              "the comparator to test precision this run.", file=sys.stderr)
        return 4
    if false_pilot_fail:
        print("\nFAIL: a real controller was wrongly classified pilot (would be suppressed).",
              file=sys.stderr)
        return 2
    print(f"\nPASS: void controls green, {cohort_reached} real segments reached the comparator, "
          "and none was wrongly classified pilot (no controller suppressed).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
