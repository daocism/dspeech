# reviewer — model-pack execution gate cycle

Run ID: `dspeech-builder-20260524T150007Z-0433753d`
Role: reviewer (distinct-skeptical-persona, fresh context — formed hypothesis from diff before reading rationale)
Date: 2026-05-24
Verdict: **APPROVE** — no blocking findings.

## Slice under review

Narrow execution gate: `VoiceFilterPipeline` must not run a real speaker
identifier unless `ModelPackState` is `.installed` (ADR 0008 installed-only /
no-silent-auto-download contract).

- Gate commit: `3dfc246 fix(voice-filter): gate speaker model execution`
- State-shell commit (context): `743f3a0 feat(voice-filter): add model pack state shell`
- Run note: `e024f20 docs(voice-filter): record model-pack execution gate run`
- Tester artifact: `.ai/runs/dspeech-builder-20260524T150007Z-0433753d-tester-unit.md` (PASS, green twice on mac24)

## Findings

**No blocking findings.** Checklist walked security → correctness → trust →
quality → shape → verification. Data flow traced for `capability`,
`requireInstalledModelPack`, `enrollPilot`, `classify`.

### Verified against the brief's review scope

- **No FluidAudio dependency / network / download code added.** `grep` for
  `FluidAudio|huggingface|URLSession|dataTask|.download(|baseURL` across
  `Dspeech/` + `DspeechTests/` returns only a phase-2 comment in
  `LiveTranscriptionViewModel.swift:67` and two test-fixture identifier strings
  (`"fluidaudio-speaker-256"`). No SPM package, no `URLSession`, no fetch path.
- **No fake classifier / fake download.** The gate *throws*
  `LocalSpeakerIdentifierError.modelUnavailable` rather than synthesizing a
  plausible decision. The honest `UnavailableLocalSpeakerIdentifier` remains the
  wired default. ADR 0008 rejected-alternatives (fake classifier, silent
  auto-download) are upheld in code.
- **Privacy copy stays honest.** `ModelPackState.capabilityReason` strings tell
  the user the model is not installed / filtering is not active; run-note and
  `.ai/project-state.md` both state pilot voices remain unfiltered. No overclaim.
- **`capability`, `enrollPilot`, `classify` agree on installed-only.** All three
  route through `modelPackState.isInstalled`:
  - `capability` (VoiceFilterPipeline.swift:49-58) → `.ready` only when identifier
    available **and** pack installed; otherwise `.unavailable`.
  - `enrollPilot` (`:97`) calls `requireInstalledModelPack()` *before*
    `identifier.enroll`.
  - `classify` (`:197`) calls it *before* `identifier.classify`.
  The identifier is never executed in any non-installed state. Confirmed `.disabled`
  (pack present, feature off) also blocks — `isInstalled` is false for `.disabled`.
- **Tests are red-for-old / green-for-new.** Against pre-gate code, the
  `FakeIdentifier` enroll/classify would have returned successfully and the new
  `absentPack*ThrowsModelUnavailable` / `disabledPack*Throws*` cases'
  `Issue.record("expected … to throw")` would fire → tests fail. With the gate they
  pass. `installedPack*` cases guard the happy path against over-gating
  (regression guards, pass both old and new). Tester verified `** TEST SUCCEEDED **`
  twice on iPhone 17 Pro / iOS 26.4.
- **`project.pbxproj` discipline.** The gate commit `3dfc246` did **not** touch
  the pbxproj (VoiceFilterTests.swift was already registered). The shell commit
  `743f3a0` added `ModelPackState.swift` by **appending new IDs** (build file
  `A0…120`, file ref `A0…121`) to the group/sources phase. No existing ID was
  renumbered. Compliant with CLAUDE.md hard constraint.

### Correctness note (non-blocking, verified-safe)

The `classify` gate sits *after* the existing `guard enabled, !profiles.isEmpty`
early-return (VoiceFilterPipeline.swift:194-197). So a disabled-flag or
empty-profile pipeline returns `.nonPilot(bestPilotScore: 0)` without throwing,
even when the pack is absent. **This does not violate the slice contract** — the
early-return path never calls `identifier.classify`, so no real identifier
executes. It is "nothing to classify" semantics, consistent with
`LiveTranscriptionViewModel.swift:62-70`. Traced and accepted; the tester flagged
the same boundary.

Edge case considered: a profile persisted from a prior `.installed` session, then
pack deleted (`installed → absent`) while `enabled == true` and profiles non-empty
→ `classify` *throws* `.modelUnavailable` rather than silently returning. Correct
fail-fast behavior; the caller boundary handles it.

## LOW (cosmetic — not requested as a fix this cycle)

- `ModelPackState.capabilityReason`'s `.installed` branch string ("Модель
  установлена, но локальный распознаватель недоступен в этой сборке.") is
  unreachable from its two current callsites: both `capability` and
  `requireInstalledModelPack` only evaluate `capabilityReason` when
  `isInstalled == false`. The string reads as intended for a future
  "installed-pack-but-identifier-unavailable-in-this-build" UI state that is not
  yet wired. No effect on the gate; recorded for whoever lands the FluidAudio
  adapter. Investigate, do not fix this cycle.

## Notes on tests

The tests would catch a real regression: removing either
`requireInstalledModelPack()` call flips the `absent`/`disabled` throw cases back
to silent success, failing them. Determinism is sound — fixed
`Date(timeIntervalSince1970:)`, per-test unique `UserDefaults` suite via `UUID()`,
`defer` cleanup, no clock/randomness/network. Storage corrupt/missing → `.absent`
and `.acquiring` cold-start → `.absent` are both covered (recovery never
fabricates `.installed`).

Process echo-chamber note (non-blocking, recorded for the improvement log): the
gate commit `3dfc246` bundling production code + tests was authored under the
`AI Office tester-unit` identity, not `engineer-generic`. Role separation between
implementer and tester was not preserved for this slice. The diff itself is
correct and I verified it independently from a fresh context; flagging the
process, not the code.

## Notion / project closeout

**Notion update NOT performed — no Notion MCP tool available in this environment.**
`ToolSearch` for `notion` and `notion update page task` returned no matching
deferred tools; no `mcp__*notion*` surface exists in this run. This is the
equivalent of NOT_FOUND/unavailable. Per the mission brief, Andrei was **not**
asked in this cycle. The status that would have been written to Notion task
`369dfa2b-7893-814c-be7e-e7cea26486a6` is recorded here and in the repo run
artifact instead:

- **Slice chosen:** gate `VoiceFilterPipeline` so no real speaker identifier runs
  unless `ModelPackState == .installed` (ADR 0008 installed-only contract).
- **Commit(s):** `3dfc246` (gate + tests); context `743f3a0` (state shell),
  `e024f20` (run note/docs); reviewer artifact this commit.
- **Tests/evidence:** `ModelPackStateStorageTests` (7) + 7 new
  `VoiceFilterPipelineTests` gate cases; full `DspeechTests` green twice on mac24
  (iPhone 17 Pro / iOS 26.4), `** TEST SUCCEEDED **`. `DspeechUITests` not run this
  slice.
- **Remaining blocker(s):** Apple Developer / TestFlight credentials; physical
  iPhone + real external ATC audio hardware; real-world ATC sample audio for
  replay fixtures; mac24 Claude login *only if* direct mac24 workers (not
  ubuntu-vm→mac24 SSH) become necessary.
- **Next highest-leverage slice:** concrete `LocalSpeakerIdentifier`
  (FluidAudio/CoreML) swapped in **only** when pack is `.installed`, plus the
  download/import UX (CTA → size disclosure → progress → cancel → retry → delete)
  and the ADR-0008 network-deny / source-override / privacy-badge-invariance
  integration tests from `docs/eval/local-speaker-model-pack-validation.md`.

## Residual risks

- The slice proves the *execution gate*, not the end-to-end privacy guarantee.
  Network-deny, download-boundary, source-override (`baseURL`), and
  privacy-badge-invariance tests remain unwritten because no backend exists yet —
  all enumerated in the eval doc and the run note. Tracked, not regressed.
- Pilot voices remain unfiltered until the real backend lands (unchanged,
  honestly documented).
- No flight-safety certification claimed or implied; route-health and voice-filter
  are advisory.

checklist_passed: [security, correctness, trust, quality, shape, verification]
notable_strengths: the gate throws rather than fakes, three surfaces
(`capability`/`enroll`/`classify`) agree on `isInstalled`, and pbxproj registration
appended new IDs without renumbering — fully honoring ADR 0008 and CLAUDE.md hard
rules 2/3.
