# FluidAudio local speaker-identifier contract — upstream verification

Date: 2026-05-25
Role: researcher-docs (AI Office run `dspeech-builder-20260525T070045Z-aac9d282`)
Branch: `feat/local-pilot-voice-filter`
Governs the next slice of: ADR 0008 (local speaker model-pack readiness), ADR 0007 (voice-filter phasing)
Related: ADR 0002 (privacy: local-only by default), ADR 0004 (no hardware purchase), `docs/eval/local-speaker-model-pack-validation.md`, `docs/research/2026-05-21-local-atc-speaker-filter.md`

> Purpose: freeze the *current* FluidAudio upstream contract so the implementation worker wires a real `FluidAudioSpeakerIdentifier` against verified symbols, not against the version strings drifting through earlier run-notes (`0.7.9` / `0.12.4` / `0.14.7` all appear in the tree — only one is current; see §1). Every API symbol below was read from upstream docs and the GitHub repo on 2026-05-25, not from memory.

---

## 0. Method & verification status

- Context7 MCP was **unavailable** in this worker (permission-denied, non-interactive mode). Verification was done directly against the authoritative upstream — `docs.fluidinference.com` rendered Markdown, the GitHub Releases/Tags API, and `Package.swift` on `main`. For a fast-moving SDK this is *higher* authority than the Context7 cache, which is exactly the staleness this role exists to catch.
- All `curl` fetches succeeded; access date for every source is 2026-05-25 (links in §9).

**Verification matrix**

| Claim | Source | Verified |
|---|---|---|
| Latest release `v0.14.7` (2026-05-19) | GitHub Releases API `/releases/latest` | ✅ |
| `swift-tools-version: 6.0`, platforms macOS 14 / iOS 17 | `Package.swift` on `main` | ✅ |
| Products `FluidAudio` (no GPL) / `FluidAudioTTS` (GPL ESpeakNG) | installation.md | ✅ |
| Embedding `[Float]`, 256-dim, **L2-normalized** | speaker-manager.md (`Speaker` model) | ✅ |
| `extractEmbedding`, `performCompleteDiarization`, `DiarizerModels.load/downloadIfNeeded` | diarization/getting-started.md, reference/api.md | ✅ |
| `SpeakerManager` symbols (`assignSpeaker`, `findSpeaker`, `initializeKnownSpeakers`) | speaker-manager.md | ✅ |
| `ModelRegistry.baseURL` / `REGISTRY_URL` override | configuration.md | ✅ |
| Diarization weights = Pyannote segmentation + WeSpeaker embeddings | reference/models.md | ✅ |
| Cosine **distance** semantics (lower = same speaker) | speaker-manager.md "Cosine Distance Guide" | ✅ |

---

## 1. Package / product / version recommendation (exact)

**STALE-DOC WARNING — do not copy the version from the docs.** The hosted `installation.md` page still shows `from: "0.7.9"` and `pod 'FluidAudio', '~> 0.7.8'`, and `introduction.md` claims "Swift 5.10+". The **actual** repository state on 2026-05-25:

- Latest release: **`v0.14.7`** (published 2026-05-19).
- `Package.swift` on `main`: `swift-tools-version: 6.0`; `platforms: [.macOS(.v14), .iOS(.v17)]`; `dependencies: []` (no third-party SPM deps; internal targets `FastClusterWrapper`, `MachTaskSelfWrapper`).

Pin (matches ADR 0007 §Phase-2 condition and the GitHub release, **not** the stale docs page):

```swift
// Package.swift / Xcode SPM
.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.14.7"),

// target dependency — CORE PRODUCT ONLY (no GPL):
.product(name: "FluidAudio", package: "FluidAudio")
```

- Use **`FluidAudio`**, never `FluidAudioTTS`. The TTS product bundles ESpeakNG (GPL-3.0); the core product is dependency-clean and license-compatible (Apache-2.0). Dspeech needs VAD + diarization/embedding only, so TTS is irrelevant.
- iOS 17+ / Swift 6 requirement is satisfied by Dspeech (iOS 26, Swift 6 strict concurrency). No platform-floor conflict.
- Do **not** add the dependency until the ADR 0008 acquisition + network-deny gates are in the same branch (ADR 0007 §Phase-2: "Until those four conditions are met, we do not import FluidAudio as an SPM dependency").

---

## 2. Swift API for enrollment and classification (verbatim symbols)

FluidAudio does **not** expose a single "speaker identifier" object. The pieces Dspeech's `LocalSpeakerIdentifier` protocol needs are assembled from `DiarizerManager` (embedding extraction) + optionally `SpeakerManager` (matching) + `VadManager` (speech gating). All inference is on-device (ANE). **Finding: there is enough public API — no lower-risk-step-first fallback is required for the core capability.** The risk is not API absence; it is (a) model acquisition under local-only (§3) and (b) a cosine-distance-vs-score semantics mismatch (§2.4).

### 2.1 Audio format (all pipelines)

All pipelines expect **16 kHz mono Float32** `[Float]`. Dspeech's `VoiceFilterSpeechAudioBufferGate` already extracts `monoFloatSamples(from:)` (float32 mono / averaged-stereo) — but verify the **sample rate is 16 kHz** before handing samples to FluidAudio; the Apple tap buffers are typically 44.1/48 kHz. Use FluidAudio's own converter to be safe:

```swift
let converter = AudioConverter()
let samples = try converter.resampleBuffer(pcmBuffer)      // AVAudioPCMBuffer -> [Float] @16kHz mono
// or for file fixtures:
let samples = try converter.resampleAudioFile(path: "fixture.wav")
```

Each `AudioConverter` is stateless; reuse one instance.

### 2.2 Model handles

```swift
// OFFLINE / staged (REQUIRED for installed-state operation — no network):
let models = try await DiarizerModels.load(
    localSegmentationModel: segmentationURL,   // .../pyannote_segmentation.mlmodelc
    localEmbeddingModel:    embeddingURL        // .../wespeaker_v2.mlmodelc
)

// AUTO-DOWNLOAD (HuggingFace) — FORBIDDEN outside the explicit `.acquiring` state (§3):
let models = try await DiarizerModels.downloadIfNeeded()
```

```swift
let diarizer = DiarizerManager()                 // or DiarizerManager(config: DiarizerConfig(...))
diarizer.initialize(models: models)
```

`DiarizerConfig` knobs (defaults shown): `clusteringThreshold: 0.7`, `minSpeechDuration: 1.0`, `minSilenceGap: 0.5`, `minActiveFramesCount: 10.0`, `debugMode: false`.

### 2.3 Enrollment — `enroll(samples:sampleRate:) -> VoicePrintVector`

The enrollment primitive is **`DiarizerManager.extractEmbedding`**, which returns a 256-dim L2-normalized `[Float]`:

```swift
// upstream (diarization/getting-started.md "Known Speaker Recognition"):
let aliceEmbedding = try diarizer.extractEmbedding(aliceAudio)   // -> [Float], 256-dim, L2-normalized
```

Dspeech adapter mapping:

```swift
func enroll(samples: [Float], sampleRate: Double) async throws -> VoicePrintVector {
    // recommend VAD-gating the capture first (§2.5) for clean enrollment
    let embedding = try diarizer.extractEmbedding(samples)        // [Float], count == 256
    guard embedding.count == embeddingDimension else {            // embeddingDimension = 256
        throw LocalSpeakerIdentifierError.incompatibleDimension(expected: embeddingDimension, got: embedding.count)
    }
    return VoicePrintVector(values: embedding, quality: /* derive from VAD voiced-duration */)
}
```

The 256-dim agrees with `UnavailableLocalSpeakerIdentifier.embeddingDimension = 256` and `VoicePrintVector` — the dimension-agreement acceptance gate (ADR 0008) is satisfiable by asserting `extractEmbedding(...).count == 256`.

### 2.4 Classification — `classify(samples:sampleRate:profiles:) -> SpeakerMatchDecision`

Two viable strategies. **Recommended: Strategy A (manual cosine over enrolled centroids)** — it keeps the decision logic in Dspeech's pure, testable functional core and avoids `SpeakerManager`'s stateful in-memory DB (which is designed for "discover speakers across a meeting", not "is this one of my N enrolled pilots").

**Strategy A — extract + manual cosine (recommended):**

```swift
func classify(samples: [Float], sampleRate: Double, profiles: [PilotVoiceProfile]) async throws -> SpeakerMatchDecision {
    let probe = try diarizer.extractEmbedding(samples)           // [Float] 256, L2-normalized
    // best cosine SIMILARITY against each enrolled centroid (both vectors L2-normalized → dot product == cosine):
    let best = profiles
        .map { (slot: $0.slot, score: dot(probe, $0.voicePrint.values)) }
        .max(by: { $0.score < $1.score })
    // map to SpeakerMatchDecision using docs/eval thresholds (pilotMatchThreshold ~0.70, nonPilotCeiling ~0.55)
}
```

**Strategy B — `SpeakerManager` lookup:**

```swift
let sm = SpeakerManager(speakerThreshold: 0.65, embeddingThreshold: 0.45,
                        minSpeechDuration: 1.0, minEmbeddingUpdateDuration: 2.0)
sm.initializeKnownSpeakers([Speaker(id: "pilot-primary", name: "...", currentEmbedding: centroid)])
let (id, distance) = sm.findSpeaker(with: probeEmbedding)        // -> (String, Float) cosine DISTANCE
```

> ⚠️ **CRITICAL semantics gotcha — distance vs. score.** FluidAudio's `SpeakerManager` and its "Cosine Distance Guide" speak in **cosine *distance*** (lower = same speaker: `< 0.3` very-high-confidence same, `> 0.9` different). Dspeech's `docs/eval/local-speaker-model-pack-validation.md` §3 and `SpeakerMatchConfig` speak in **cosine *score/similarity*** (higher = pilot: `pilotMatchThreshold ~0.70`). These are inverses for L2-normalized vectors: `similarity ≈ 1 − distance`. If the engineer feeds a FluidAudio `distance` into a Dspeech `score` threshold unconverted, **every pilot will be mis-routed as non-pilot (or vice versa)** — a safety-adjacent bug. Strategy A sidesteps this by computing similarity directly as the dot product of two already-L2-normalized embeddings. If Strategy B is used, convert explicitly and add a test that pins the conversion.

`insufficientSpeech`: derive from VAD (§2.5) — if no/too-short voiced segment, return `.insufficientSpeech` (which `routeBeforeTranscription` already maps to fail-open `.transcribe`, per `VoiceFilterPipeline.swift:157`). `mixed` has no direct FluidAudio primitive; produce it from the threshold band (`nonPilotCeiling ≤ best < pilotMatchThreshold`) per the eval doc.

### 2.5 VAD (recommended, for enrollment quality + insufficientSpeech)

```swift
let vad = try await VadManager(config: VadConfig(defaultThreshold: 0.75))
var seg = VadSegmentationConfig.default
seg.minSpeechDuration = 0.25; seg.minSilenceDuration = 0.4; seg.speechPadding = 0.12
let clips = try await vad.segmentSpeechAudio(samples, config: seg)   // [audio buffers] ready for embedding
```

Silero VAD v6 runs on CPU (minimal memory), 256 ms windows. Use it to (a) reject squelch/too-short clips → `.insufficientSpeech`, and (b) clean enrollment audio before `extractEmbedding`.

---

## 3. Model acquisition behavior & the local-only guard (the privacy core)

### 3.1 Default behavior (what to NOT trigger)

- Models auto-download from **HuggingFace** on first use. For diarization the repo is **`FluidInference/speaker-diarization-coreml`** (Pyannote segmentation + WeSpeaker embeddings). The trigger is `DiarizerModels.downloadIfNeeded()` (and any `DiarizerManager` path that internally calls it).
- macOS cache path after download: `~/Library/Application Support/FluidAudio/Models/<repo>`. (iOS equivalent is the app's Application Support dir; same `FluidAudio/Models/<repo>` layout.)
- This silent first-use fetch is **exactly** the ADR 0002 / ADR 0008 §"no silent auto-download" violation. It must never fire outside the user-initiated `.acquiring` state.

### 3.2 Override the source (mirror / air-gap)

```swift
import FluidAudio
ModelRegistry.baseURL = "https://your-mirror.example.com"   // programmatic — highest priority
```

Env-var equivalents (CLI/testing): `REGISTRY_URL` (alias `MODEL_REGISTRY_URL`). **Priority: programmatic `ModelRegistry.baseURL` > env > default HuggingFace.** This satisfies ADR 0008 §"The model source is overridable" and the eval-doc source-override test: set `ModelRegistry.baseURL` to a `file://` or `localhost` URL and assert the download path honors it.

### 3.3 Offline / installed-state operation (no network, ever)

Once the pack is `installed`, operate **only** via the staged-bundle loader — it touches no network:

```swift
let base = installedPackDirectory   // app's Application Support, NOT HuggingFace
let models = try await DiarizerModels.load(
    localSegmentationModel: base.appendingPathComponent("pyannote_segmentation.mlmodelc"),
    localEmbeddingModel:    base.appendingPathComponent("wespeaker_v2.mlmodelc")
)
```

### 3.4 What Dspeech must do to guarantee no silent fetch under local-only

1. **Never call `DiarizerModels.downloadIfNeeded()` (or any auto-download initializer) outside `ModelPackState.acquiring`.** The `FluidAudioSpeakerIdentifier` constructed for `installed` state must take an already-staged directory and use `DiarizerModels.load(local…:)` exclusively. A missing pack must `throw LocalSpeakerIdentifierError.modelUnavailable` (today's behavior), not fall through to a fetch.
2. **Gate the adapter on `modelPackState.isInstalled`** — `VoiceFilterPipeline.capability`/`requireInstalledModelPack()` already enforce this (`VoiceFilterPipeline.swift:54,65`). Wire `FluidAudioSpeakerIdentifier` into `VoiceFilterPipeline(identifier:)` only when `.installed`; keep `UnavailableLocalSpeakerIdentifier` for `absent`/`acquiring`/`failed`/`disabled`.
3. **Set `ModelRegistry.baseURL` before any acquisition** so even the single `.acquiring` download targets a source under our control (or, if HuggingFace is accepted, it is the explicit, disclosed one-time event — never implicit).
4. **The download channel is one-directional model bytes only.** No FluidAudio API uploads audio; `extractEmbedding`/`performCompleteDiarization`/`segmentSpeech` are pure local inference. The network-deny test (eval §1) asserts zero egress during `enroll → classify → routeBeforeTranscription`.
5. **`InstalledModelPack.source`** (already in `ModelPackState.swift:33`) records the resolved `ModelRegistry.baseURL`; `checksumSHA256` verifies the staged bundle before flipping to `installed`.

---

## 4. Minimum honest, testable implementation slice for today

The full acquisition UX (real downloader, progress, cancel) is a large piece. The lowest-risk slice that is **honest** (no fake), **testable today on mac24/CI**, and moves the inert gate toward live is:

**Slice: `FluidAudioSpeakerIdentifier` offline-load adapter behind the existing state machine — no in-app downloader yet.**

1. SPM-add `FluidAudio` pinned `from: "0.14.7"`, core product only (§1). This is the ADR-0007-gated step; it is allowed now **only if** the network-deny test lands in the same branch.
2. Implement `FluidAudioSpeakerIdentifier: LocalSpeakerIdentifier`:
   - `init` takes a **staged local bundle directory** (no URL fetch); builds `DiarizerManager` via `DiarizerModels.load(local…:)`.
   - `embeddingDimension = 256`; `availability = .available` once `initialize(models:)` succeeds, else `.unavailable(reason:)`.
   - `enroll` → VAD-gate (§2.5) → `extractEmbedding` → `VoicePrintVector` (§2.3).
   - `classify` → Strategy A manual cosine similarity over enrolled centroids → `SpeakerMatchDecision` mapped through eval-doc thresholds (§2.4), with `.insufficientSpeech` from VAD.
3. **No in-app downloader this slice.** The `.absent` "Скачать пакет…" CTA stays disabled (as today); the pack reaches `.installed` only via a **test-staged bundle** (a `.mlmodelc` committed/sideloaded into the test resources, or downloaded once on mac24 into the sim's Application Support). This keeps CLAUDE.md hard rules 2 & 3 intact — no fake downloader pretending to fetch.
4. `LiveTranscriptionViewModel` still synthesizes `.nonPilot(bestPilotScore: 0)` in the live UI path until the pack can actually reach `.installed` on a user device; the new adapter is exercised by the gate + tests. Honesty preserved: no claim pilots are filtered in a shipped build until acquisition exists.

If the engineer judges the SPM-add itself too large for one slice, the **strictly-lower-risk fallback** is documentation-only: land this contract + the network-deny *test harness skeleton* (egress-blocked fixture runner) with `UnavailableLocalSpeakerIdentifier`, deferring the SPM-add. But the API is sufficient (§2) — the adapter slice above is the recommended honest step.

---

## 5. Acceptance gates

### For the engineer
- [ ] SPM pin is exactly `from: "0.14.7"`, product `FluidAudio` (NOT `FluidAudioTTS`); `git`-resolved version recorded in the run note. No GPL in the dependency graph.
- [ ] `FluidAudioSpeakerIdentifier` uses `DiarizerModels.load(localSegmentationModel:localEmbeddingModel:)` only; **no `downloadIfNeeded()` / auto-download call anywhere outside `.acquiring`** (grep the diff for `downloadIfNeeded`, `downloadAndLoad`).
- [ ] Adapter swapped into `VoiceFilterPipeline(identifier:)` only when `modelPackState.isInstalled`; `absent/acquiring/failed/disabled` keep `UnavailableLocalSpeakerIdentifier`.
- [ ] `ModelRegistry.baseURL` is set before any acquisition path; `InstalledModelPack.source` records it.
- [ ] Cosine **distance→similarity** conversion is explicit and unit-pinned if Strategy B is used; Strategy A documents that dot-product == cosine for L2-normalized embeddings.
- [ ] `embeddingDimension == 256` asserted against the live backend (`extractEmbedding(...).count`).
- [ ] Samples are 16 kHz mono Float32 before reaching FluidAudio (use `AudioConverter`); not assumed from the Apple tap rate.

### For the tester
- [ ] **Network-deny integration test** (eval §1): `enroll → classify → routeBeforeTranscription` against replay fixtures with all egress blocked → zero failed/pending requests, correct decisions. Green on iPhone 17 Pro / iOS 26.4 sim.
- [ ] **Missing-pack-throws** stays green: `absent` → `enroll`/`classify` throw `modelUnavailable`, no implicit fetch (already green per eval §5).
- [ ] **Source-override test**: `ModelRegistry.baseURL` set to a `file://`/local URL is honored by the acquisition path.
- [ ] **Replay fixtures** (eval §2) each produce their labeled `SpeakerMatchDecision`/routing: single-pilot→`.pilot`/discard; non-pilot→`.nonPilot`/transcribe; two-pilot→both discard; overlap→`.mixed`/transcribe-with-badge; squelch→`.insufficientSpeech`/transcribe.
- [ ] **Threshold calibration** values measured on the corpus and written back into eval §3 (cosine *similarity* space; note the distance inversion).
- [ ] Privacy `LOCAL`/`CLOUD` badge invariance across all five model-pack states (download is not a cloud mode).
- [ ] mac24 `xcodebuild build test` full Dspeech suite green; command + result pasted into the run note (assertions without pasted output don't count, per eval §5).

---

## 6. Gotchas / common mistakes

1. **Stale install docs** — `installation.md` says `0.7.9` and Swift 5.10; the real release is `v0.14.7` and `Package.swift` is `swift-tools-version: 6.0`. Pin from the GitHub release, not the docs page.
2. **Distance vs. similarity inversion** (§2.4) — the single highest-risk correctness trap. FluidAudio = distance (low=match); Dspeech eval = similarity (high=match). Mishandling silently inverts pilot routing.
3. **Auto-download is the default** — merely constructing the pipeline via the "Quick Start" (`downloadIfNeeded()`) path triggers a HuggingFace fetch. The offline `load(local…:)` path is opt-in and is the only ADR-0002-safe path for installed operation.
4. **`SpeakerManager` is for `DiarizerManager` (streaming) only** — its own note says it is *not* compatible with `OfflineDiarizerManager` (which uses VBx clustering). If you mix managers you'll get a runtime/seam mismatch. Strategy A (manual cosine) avoids the coupling entirely.
5. **TTS = GPL** — `FluidAudioTTS` pulls ESpeakNG (GPL-3.0). Dspeech must never add that product; core `FluidAudio` is Apache-2.0 and dependency-clean.
6. **Sample rate** — pipelines require 16 kHz mono Float32. The Apple input tap is usually 44.1/48 kHz; `monoFloatSamples(from:)` fixes channels but not rate. Resample via `AudioConverter` or embeddings will be garbage.
7. **Bundle filenames** — staged diarization bundles are `pyannote_segmentation.mlmodelc` + `wespeaker_v2.mlmodelc` (per the offline example). Confirm exact names against the `FluidInference/speaker-diarization-coreml` HF repo when staging, since the embedding bundle name (`wespeaker_v2`) can rev with model versions.
8. **Cold-start half-download** — `ModelPackState.recoveredAfterColdStart()` already resolves `.acquiring → .absent`; ensure the FluidAudio cache dir is treated as untrusted until checksum-verified, so a partially-written `.mlmodelc` never loads as `installed`.

---

## 7. Notion

No Notion task fetch was attempted from this worker (no connector access in scope). Prior run-notes (2026-05-24 pre-ASR gate) record the active task `https://www.notion.so/369dfa2b7893814cbe7ee7cea26486a6` returning `NOT_FOUND` through the connector. Not a blocker for this research artifact; recorded here per the mission constraint.

---

## 8. What did NOT change vs. earlier internal notes

- ADR 0008 state machine, privacy contract, and acceptance gates stand unchanged — this doc fills in the *how* (verified symbols + version) they deferred.
- `embeddingDimension = 256` confirmed against upstream (was an assumption in ADR 0008; now verified: WeSpeaker embeddings are 256-dim L2-normalized).
- `ModelRegistry.baseURL` override confirmed present and documented (ADR 0007/0008 relied on it).

---

## 9. Sources (all accessed 2026-05-25)

- FluidAudio docs index — https://docs.fluidinference.com/llms.txt
- Installation (note: version string stale) — https://docs.fluidinference.com/installation.md
- Configuration (`ModelRegistry.baseURL`, `REGISTRY_URL`) — https://docs.fluidinference.com/configuration.md
- Diarization getting started (`extractEmbedding`, `DiarizerModels.load`, known-speaker, config) — https://docs.fluidinference.com/diarization/getting-started.md
- SpeakerManager API (`assignSpeaker`/`findSpeaker`/`initializeKnownSpeakers`, `Speaker` model, 256-dim L2-norm, cosine distance guide) — https://docs.fluidinference.com/diarization/speaker-manager.md
- Manual model loading (offline staging, cache path) — https://docs.fluidinference.com/guides/manual-model-loading.md
- VAD getting started (`VadManager`, `segmentSpeechAudio`, Silero v6) — https://docs.fluidinference.com/vad/getting-started.md
- Models catalog (Pyannote + WeSpeaker, HF repos) — https://docs.fluidinference.com/reference/models.md
- API reference (`DiarizerManager`/`VadManager`/`AudioConverter` method tables) — https://docs.fluidinference.com/reference/api.md
- Audio conversion (`AudioConverter.resampleBuffer/resampleAudioFile`) — https://docs.fluidinference.com/guides/audio-conversion.md
- Introduction (platform/Swift requirements — note Swift "5.10+" claim is below the real `Package.swift` 6.0) — https://docs.fluidinference.com/introduction.md
- GitHub — repo, latest release `v0.14.7` (2026-05-19), tags, `Package.swift` on `main` — https://github.com/FluidInference/FluidAudio
- HuggingFace diarization model repo (`pyannote_segmentation` + `wespeaker_v2` CoreML) — https://huggingface.co/FluidInference/speaker-diarization-coreml
- Apple `SFSpeechRecognizer.supportsOnDeviceRecognition` (analogous on-device-vs-network gating principle) — https://developer.apple.com/documentation/Speech/SFSpeechRecognizer/supportsOnDeviceRecognition
