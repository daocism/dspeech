# Local iOS ATC-only transcription — speaker-filtered pipeline

Date: 2026-05-21
Owner: `researcher-web` (AI Office)
Scope: validate the technical basis for a fully on-device pipeline that (a) enrolls 1–2 pilot voices, (b) classifies each speech segment as pilot vs non-pilot, (c) discards pilot audio before STT, (d) transcribes only non-pilot audio locally, (e) optionally filters ATC traffic by aircraft callsign.

> **Verification status (read before relying on this doc).** Inside this dispatch the WebFetch / WebSearch / Context7 permissions were blocked, so the primary-source pages listed under **Sources** were *not* fetched fresh on 2026-05-21. The doc was assembled from (1) the CEO's pre-validated high-signal facts for this brief and (2) the canonical primary-source URLs documented below. Before this doc is treated as authoritative, the listed URLs must be re-fetched (via Apple Developer docs, FluidAudio GitHub, Picovoice docs) and any drift reconciled. Every claim below is tagged `[verified-by]` with one of: `ceo-baseline`, `apple-docs-canonical`, `fluidaudio-readme-canonical`, `picovoice-docs-canonical`, `reasoned`.
>
> **2026-05-22 verification update (tech-lead dispatch, Notion run `notion-20260522T070523Z-ab0d0878a53fbebf`):** FluidAudio repo re-fetched live from `https://github.com/FluidInference/FluidAudio` via WebFetch. Confirmed:
> - **License: Apache-2.0** ✅ — README "Apache 2.0 — see LICENSE for details".
> - **SPM package: `https://github.com/FluidInference/FluidAudio.git`** ✅ — latest tag `v0.14.7` (2026-05-19); docs reference `from: "0.12.4"`.
> - **Public API surface** ✅ — `VadManager` (`process`, `segmentSpeech`, `processStreamingChunk`), `DiarizerManager` / `OfflineDiarizerManager` / `LSEENDDiarizer` / `Sortformer` for speaker embedding/diarization.
> - **Platforms** ✅ — Swift 6.0+, macOS + iOS; async/await idiomatic. CLI is macOS-only (we want the library).
> - **Offline guarantee: ⚠️ NOT free** — README quote: *"Models auto-download on first use. If your network restricts Hugging Face access, set an HTTPS proxy."* `ModelRegistry.baseURL` and `REGISTRY_URL` env var allow mirror override; default source is `huggingface.co`. **No weights are bundled in the SPM.** This means a fresh install will perform a runtime network fetch to HuggingFace on first VAD/diarization use, which violates the literal "no audio/network at runtime in `.localOnly`" reading of ADR 0002 absent an explicit, user-gated AssetInventory-style "Download voice-filter pack" CTA + post-download network-deny integration test.
>
> Apple Speech URLs were not re-fetched fresh this dispatch — they remain unchanged from 2026-05-21 (verified-by: ceo-baseline + apple-docs-canonical) and are not the dispatch's blocking question.

## TL;DR

Ship the MVP on **Apple SpeechAnalyzer + FluidAudio**, no third-party paid SDK in the critical path.

- **ASR**: `SpeechAnalyzer` with `SpeechTranscriber` on iOS 26+ devices/locales where `isAvailable == true` and the locale is in `installedLocales` (after `AssetInventory` download). Fall back to `DictationTranscriber` on devices/locales where `SpeechTranscriber` is not available but offline dictation is. `[verified-by: ceo-baseline, apple-docs-canonical]`
- **Speaker filtering** (the core of this brief): **FluidAudio** for on-device VAD + speaker-embedding extraction + per-segment speaker identification. Use the WeSpeaker/Pyannote-style path (explicit enrollment + speaker database) because we need pilot-vs-non-pilot pre-enrollment, not arbitrary diarization. `[verified-by: ceo-baseline, fluidaudio-readme-canonical]`
- **Callsign filter**: implemented as a **text-stage gate after ASR**, applied only to non-pilot transcripts (= ATC traffic), suppressing transcripts that do not reference the configured aircraft callsign within a short look-back. It is **not** the primary speaker classifier. `[verified-by: reasoned]`
- **Picovoice Eagle**: **rejected** for this product. The brief instruction is "treat as rejected unless you prove no runtime network/API dependency"; Picovoice's documented `AccessKey` model has activation/validation behavior that is incompatible with the ADR 0002 "local-only by default" promise. `[verified-by: ceo-baseline, picovoice-docs-canonical]`
- **WhisperKit / Argmax**: held as fallback ASR if Apple Speech's per-locale offline coverage turns out to be too narrow for the aviation phraseology set. Not in MVP critical path. `[verified-by: reasoned]`

## Recommended pipeline

```
AVAudioEngine input tap (16 kHz mono, intercom/wired preferred)
   │
   ├─► FluidAudio VAD  ──► drop silence / engine noise / squelch
   │
   ├─► FluidAudio speaker-embedding extraction per speech segment
   │
   ├─► On-device cosine classifier vs enrolled embeddings
   │     • {pilot_1, pilot_2}  → speaker == pilot
   │     • otherwise           → speaker == non-pilot (presumed ATC / other cockpit)
   │
   ├─► if pilot:        DISCARD segment, do not invoke ASR
   │
   └─► if non-pilot:    feed segment to SpeechAnalyzer(SpeechTranscriber | DictationTranscriber)
            │
            └─► (optional) ATC-relevance gate on transcript text:
                  • match configured aircraft callsign (regex w/ phonetic variants)
                  • or pass-through if "callsign filter" is OFF
```

### Enrollment (Pilot 1 / Pilot 2)

- Capture ~30–60 s of clean speech per pilot (preferred source: wired intercom; built-in mic is the demo path).
- Run FluidAudio's speaker-embedding model over VAD-segmented utterances; average the resulting embeddings per pilot.
- Persist the centroid embedding in the app's local keychain/Core Data; never leaves the device under `PrivacyMode.localOnly` (ADR 0002).
- Provide a "Re-enroll" button — embeddings drift across headset changes and recording conditions.

## SDK matrix

| Capability | Apple Speech (iOS 26+) | FluidAudio | WhisperKit / Argmax | Picovoice Eagle |
|---|---|---|---|---|
| Fully on-device, no network at runtime | yes for `SpeechTranscriber` / `DictationTranscriber` once locale assets are downloaded `[ceo-baseline]` | yes, CoreML models bundled `[ceo-baseline]` | yes (CoreML Whisper variants) `[reasoned]` | **rejected** — `AccessKey` activation is documented behavior; cannot guarantee zero network `[picovoice-docs-canonical, ceo-baseline]` |
| VAD | `SpeechDetector` module of `SpeechAnalyzer` (use for segmentation hints) `[apple-docs-canonical]` | yes — first-class API `[fluidaudio-readme-canonical]` | not its scope | not its scope |
| Speaker embedding / identification | **no** first-class enrollment API | **yes** — speaker embeddings, identification across streams; WeSpeaker/Pyannote path supports explicit DB `[ceo-baseline]` | no | yes, but rejected per row 1 |
| Diarization (unsupervised) | no | yes — LS-EEND / Sortformer recommended for low-latency `[ceo-baseline]` | no | not a true diarizer |
| ASR (English aviation) | yes — production path on iOS 26+ `[ceo-baseline]` | yes, but Apple's locale-tuned ASR is usually first choice on iOS | yes — alternative ASR if Apple's coverage is thin | n/a |
| Locale model gating | `SpeechTranscriber.isAvailable`, `installedLocales`, `supportedLocales`, downloads via `AssetInventory` `[ceo-baseline, apple-docs-canonical]` | n/a (acoustic-only models) | manual model selection | n/a |
| License / cost | Apple SDK, free | open-source (verify license in repo before ship) `[unverified-today]` | open-source (verify) `[unverified-today]` | commercial + AccessKey |
| Privacy posture vs ADR 0002 | compatible | compatible | compatible | **incompatible** |

## Offline / privacy implications

1. **Asset download is the one network event we must accept.** Apple's `SpeechTranscriber` requires its locale assets to be installed before `installedLocales` reports them; the download is an explicit `AssetInventory` call. After install, transcription runs locally. The app must (a) surface the download as a first-run / language-pack action with size disclosure, (b) never silently re-download in `.localOnly`. `[verified-by: ceo-baseline, apple-docs-canonical]`
2. **FluidAudio models** ship inside the app bundle (or are downloaded once and pinned); they must not contact any network at runtime. Verify by static analysis of the released framework + a network-deny integration test. `[verified-by: reasoned]`
3. **No audio leaves the device.** Pilot enrollment data (embeddings) and ATC transcripts both stay local. The cloud-fallback path (ADR 0002) remains available only after explicit user opt-in and is out of scope for this brief.
4. **Picovoice rejected on privacy.** The known `AccessKey` model includes activation/validation that this product cannot promise the user away. Even if Picovoice ran fully offline in some configurations, the documented default behavior is enough to fail ADR 0002's "all audio stays on your iPhone by default" promise the App Store listing makes.

## Callsign filter — design recommendation

Use callsign matching **only as a downstream ATC-relevance gate**, never as the speaker classifier. Reasons:

- **Pilot readback contains the callsign.** If callsign-match were the inclusion test, we would re-include exactly the segments we just discarded. The pipeline already drops pilot audio upstream by speaker embedding, which is the right tool. `[reasoned]`
- **ATC omits the callsign in continuation utterances.** A controller speaks "descend two thousand, contact approach 119.1" without re-saying the aircraft callsign for several seconds. A strict callsign-match gate would silently suppress critical instructions. Mitigations:
  - Sliding-window: once a callsign match fires, keep the gate "open" for N seconds (e.g. 15–30 s) or M utterances, so continuation traffic is not dropped.
  - Phonetic-alphabet normalization: match "November Six Two Three Echo Alpha" ↔ "N623EA" ↔ stripped variants. ICAO phonetic alphabet is a small fixed table; do this in code, not in the model.
  - User toggle: callsign filter is OFF by default in MVP; the pilot turns it on once they have a clean callsign string for the leg.
- **Cockpit / intercom mixes voices.** Even with a clean pilot embedding, overlapping speech (pilot + ATC under push-to-talk leakage, or pilot 1 + pilot 2) will produce mixed-embedding segments. Mitigation: when the speaker classifier's confidence is low, **transcribe but mark the segment with a "mixed-speaker" badge** rather than discarding — better to over-show than to hide ATC. `[reasoned]`
- **Overlapping speech** is an open problem in diarization; FluidAudio's Sortformer-style models handle it better than older clustering approaches, but the product must assume nonzero leakage. `[ceo-baseline]`

## Known aviation failure modes

| # | Failure | Effect | Mitigation in this design |
|---|---|---|---|
| 1 | Pilot readback contains callsign | Naive callsign filter would re-include readback we just discarded | Speaker filter runs before callsign filter; callsign filter never re-introduces pilot segments |
| 2 | ATC omits callsign in continuation instructions | Strict callsign filter hides critical instructions | Sliding-window keep-open after the first match per controller hand-off |
| 3 | Pilot 1 + Pilot 2 + ATC overlap | Embeddings mix; classifier confidence drops | Mark segments as "mixed", transcribe and surface anyway; do not silently drop |
| 4 | Headset / wiring change | Pilot embedding drifts → false-positive non-pilot | "Re-enroll" CTA in Settings; warn when classifier confidence trends down over a session |
| 5 | High SNR loss (engine noise, squelch) | VAD over- or under-segments | Engine-band high-pass + VAD threshold per audio-source profile (built-in vs wired) |
| 6 | Locale not in `installedLocales` | ASR silently degraded or unavailable | Gate UI on `isAvailable` + `installedLocales`; expose explicit "Download English (US) aviation pack" CTA |
| 7 | Non-native ATC accent | ASR WER spikes | Out of scope of this brief; tracked by `docs/eval/asr-benchmark-plan.md` |
| 8 | Two pilots on the same channel (CRJ-style two-yoke ops) | Both should be filtered out | Enroll both; centroid distance test against the union {pilot_1, pilot_2} |

## Open questions

1. **`SpeechTranscriber` aviation-domain WER** vs WhisperKit on the dspeech replay corpus. The benchmark plan in `docs/eval/asr-benchmark-plan.md` is the deciding artifact; this research does not pre-judge it.
2. **FluidAudio license** must be verified in the repo before shipping — confirm permissive (MIT/Apache-2.0/BSD) and that bundled CoreML models inherit a compatible license. Today's dispatch could not fetch the repo.
3. **Speaker embedding latency** on iPhone 15 baseline: target ≤ 100 ms per utterance so the pipeline does not stall ASR. Needs a measurement, not a guess.
4. **Per-locale offline coverage** of `SpeechTranscriber` for non-English aviation locales (Russian, Ukrainian, Spanish) is not assumed; for MVP, English-only on-device, others via translation overlay only.
5. **Re-fetch the primary sources.** Today's blocked fetches mean every URL below needs a manual re-pull before this doc graduates from "research" to "implementation contract".
6. **`SpeechDetector` vs FluidAudio VAD**: confirm which has lower latency on iOS 26 for ATC audio specifically. Two valid options; benchmark deciding.

## Sources (URLs canonical — fetch before relying)

Apple Speech (iOS 26+ on-device transcription):
- Apple Developer — Speech framework: https://developer.apple.com/documentation/speech
- Apple Developer — `SpeechAnalyzer`: https://developer.apple.com/documentation/speech/speechanalyzer
- Apple Developer — `SpeechTranscriber`: https://developer.apple.com/documentation/speech/speechtranscriber
- Apple Developer — `DictationTranscriber`: https://developer.apple.com/documentation/speech/dictationtranscriber
- Apple Developer — `SpeechDetector`: https://developer.apple.com/documentation/speech/speechdetector
- Apple Developer — `AssetInventory`: https://developer.apple.com/documentation/speech/assetinventory
- WWDC 2025 — Bringing advanced speech-to-text to your app with SpeechAnalyzer (session reference for the iOS 26 / SpeechAnalyzer rollout)

FluidAudio (Swift/CoreML VAD + diarization + speaker ID):
- FluidAudio repo: https://github.com/FluidInference/FluidAudio
- FluidAudio docs site / README (in-repo): https://github.com/FluidInference/FluidAudio#readme
- Diarization model notes (LS-EEND / Sortformer, WeSpeaker / Pyannote) — in the FluidAudio docs/README per CEO baseline

Picovoice Eagle (rejected, documented for the record):
- Picovoice Eagle product page: https://picovoice.ai/docs/eagle/
- Picovoice AccessKey / activation documentation: https://picovoice.ai/docs/quick-start/console-signup/ and https://picovoice.ai/docs/faq/picovoice/ (AccessKey behavior)

WhisperKit / Argmax (fallback ASR — not in MVP critical path):
- WhisperKit repo: https://github.com/argmaxinc/WhisperKit
- Argmax site: https://www.argmaxinc.com/

Internal anchors:
- `docs/architecture.md` — module boundaries (`Core/ASR/`, `Core/Audio/`)
- `docs/adr/0001-ios-first-local-first.md`, `docs/adr/0002-privacy-local-only-default.md` — privacy posture
- `docs/product/prd-ios-mvp.md` — MVP F1–F8 gates
- `docs/eval/asr-benchmark-plan.md` — the artifact that will decide Apple Speech vs WhisperKit
- `docs/eval/audio-input-matrix.md` — built-in vs wired vs AirPods sources

## Confidence

Medium. The recommended stack matches the CEO's pre-validated high-signal facts and the dspeech ADR posture cleanly, and there is no plausible substitute for FluidAudio in the speaker-enrollment role given Picovoice's rejection. Confidence is held below "high" until (a) the primary-source URLs above are re-fetched fresh, (b) FluidAudio's license + on-device guarantee are confirmed from the repo, and (c) the `SpeechTranscriber` aviation-WER benchmark lands.
