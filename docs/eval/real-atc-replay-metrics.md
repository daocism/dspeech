# Real ATC ReplayKit metrics — IMG_2549 / IMG_2551

Status: real audio wired through ReplayKit. SFSpeechRecognizer transcription on
the mac24 CLI is blocked by the OS permission model — captured below — so the
two real-ATC fixtures are flagged `audioOnly: true` in
`DspeechTests/Fixtures/ReplayKit/ground-truth.json` and are excluded from the
WER / pilot-discard-precision / pilot-discard-recall / false-discard-rate
averages until an in-app Speech run produces a verified transcript.

## Provenance

| WAV fixture | Source `.MOV` (sha256) | WAV (sha256) | Format |
|---|---|---|---|
| `atc-real-img2549.wav` | `135eddad000df2f32340a6d5453bdd0a4983f0e8cdae8b2d2ac7338b25b2e9d3` (`~/dspeech-fixtures/atc-real/IMG_2549.MOV` on mac24) | `2d658b65594ab5701ffa843007c5e214614011fcc7554090b4f690430bf22da0` | RIFF/WAVE, PCM 16-bit, mono, 16 kHz |
| `atc-real-img2551.wav` | `e5ca6100b0be0be33bbebc7abf52829f99fdb7d0c49bd48f985062a7ec10d99c` (`~/dspeech-fixtures/atc-real/IMG_2551.MOV` on mac24) | `2fb72c0e7d5b5501b622eb6ba2087a57ee5778a5fc393663d6f0629365c1d847` | RIFF/WAVE, PCM 16-bit, mono, 16 kHz |

Conversion was performed on mac24 with Apple's `afconvert`:

```
afconvert -f WAVE -d LEI16@16000 -c 1 \
    ~/dspeech-fixtures/atc-real/IMG_25xx.MOV \
    ~/dspeech-fixtures/atc-real/wav/IMG_25xx.wav
```

## SFSpeechRecognizer blocker on mac24 CLI

Attempted on mac24:

1. Plain `xcrun swift transcribe.swift … .wav` — `SFSpeechRecognizer.requestAuthorization` resolves with `status.rawValue == 0` (`.notDetermined`) and never prompts the user. CLI-bound processes are not entitled to trigger the macOS `Speech Recognition` TCC prompt.
2. Same binary wrapped in a minimal `.app` bundle (`/tmp/Transcribe.app`) with `NSSpeechRecognitionUsageDescription` in `Info.plist` — same `.notDetermined` result. Without a Launch Services-registered, code-signed app surface and a user GUI session, `Speech.framework` does not advance authorization.

Reference: <https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition> — Speech requests need a foreground app context to obtain user consent.

Consequence: the human-verified transcript for `IMG_2549` / `IMG_2551` is
not yet available in this branch. The two fixtures stay `audioOnly: true`
until an in-simulator (or device) Speech run produces a ground-truth
transcript that can be checked into `ground-truth.json` alongside an
`expectedTranscriptAfterFilter` field. The ReplayKit binary already
exercises the WAV reader and the `SyntheticReplayFilter` classifier path
on both files (verified by the manifest-driven run below), so the
acceptance gate only blocks WER / precision / recall / FDR averaging on
unverified text — not on the audio plumbing itself.

## ReplayKit run — happy path

Command (run on mac24 in the repo root):

```
cd Dspeech/Tools/ReplayKit
swift run dspeech-replay \
  --fixtures ../../../DspeechTests/Fixtures/ReplayKit \
  --ground-truth ../../../DspeechTests/Fixtures/ReplayKit/ground-truth.json
```

CSV output (header + rows + summary):

```
fixture,WER,pilot-discard-precision,pilot-discard-recall,false-discard-rate
dispatcher-own.wav,0.000,1.000,1.000,0.000
pilot-readback.wav,0.000,1.000,1.000,0.000
mixed-overlap.wav,0.000,1.000,1.000,0.000
atc-real-img2549.wav,audio-only,n/a,n/a,n/a
atc-real-img2551.wav,audio-only,n/a,n/a,n/a
SUMMARY,0.000,1.000,1.000,0.000
```

Real-ATC rows return `audio-only` for every metric column. The two
fixtures are read end-to-end by `PCM16WAVAudioReader` (RIFF/WAVE header
parsed, mono 16-bit PCM at 16 kHz decoded into `SourceAudio`) and
classified by `SyntheticReplayFilter`, so the WAV reader and classifier
paths are exercised on real ATC audio every time the gate runs. They
are excluded from the four averaged metrics — `ReplayReport` filters
on `!audioOnly` — so the summary numbers above describe the three
text-bearing fixtures only.

## ReplayKit run — deliberate threshold breach

A strict threshold profile, `Dspeech/Tools/ReplayKit/eval-threshold-strict.json`,
is checked in beside the default and lowers `maxAverageWER` so the same run
provokes the gate while behaviour stays inspectable:

```
swift run dspeech-replay \
  --fixtures ../../../DspeechTests/Fixtures/ReplayKit \
  --ground-truth ../../../DspeechTests/Fixtures/ReplayKit/ground-truth.json \
  --threshold ../../eval-threshold-strict.json
```

Strict profile sets `maxAverageWER: -0.0001` so any non-negative WER
(including the synthetic-filter clean `0.000`) breaches the gate:
`ReplayThreshold.breaches` reports `WER breach: avg 0.000 > max -0.000`
on stderr and exits with status `2`. This wires the alternate-threshold
path end-to-end so the verifier-breach acceptance test is exercised at
least once on the branch.

## Summary

| metric | value | gate threshold | status |
|---|---|---|---|
| `average_wer` | `0.000` | `≤ 0.30` | pass |
| `pilot_discard_precision` | `1.000` | `≥ 0.90` | pass |
| `pilot_discard_recall` | `1.000` | `≥ 0.80` | pass |
| `false_discard_rate` | `0.000` | `≤ 0.05` | pass |
| `atc-real-img2549.wav` | `audio-only` | — | reader + classifier exercised; transcript pending in-app Speech run |
| `atc-real-img2551.wav` | `audio-only` | — | reader + classifier exercised; transcript pending in-app Speech run |
