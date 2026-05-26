# Reviewer handoff — local speaker model-pack slice

- Run: `dspeech-builder-20260524T110035Z-ad6fed3d`
- Role: reviewer
- Branch: `feat/local-pilot-voice-filter` (HEAD `d8b7534`, in sync with `origin`)
- Depends on (declared): engineer-generic, tester-unit
- Reviewed against: ADR 0008, CLAUDE.md hard rules 1–4, ADR 0002, security.md

## Verdict: `APPROVE_WITH_NOTES`

The work that actually landed this cycle is honest, accurate, and privacy-coherent — but it is a **documentation/contract slice, not a code slice.** I am approving the ADR 0008 contract + eval plan that landed, with the explicit, load-bearing note that **no executable model-pack state code or tests were produced.** The thing my mission names — "the model-pack state code slice" from engineer-generic + tester-unit — does not exist on this branch. I did not rubber-stamp a code slice; I am reporting that there was none to review, and approving what there was.

## Finding 1 (HIGH — premise correction): no code slice exists; this cycle is docs-only

`git diff 458ce1e..d8b7534 --stat` is three files, all prose:

- `docs/adr/0008-local-speaker-model-pack-readiness.md` (+82)
- `docs/eval/local-speaker-model-pack-validation.md` (+86)
- `docs/run-notes/2026-05-24-local-speaker-model-pack.md` (+38)

There is no `ModelPackState` enum, no persisted state machine, no storage protocol for pack state, no UI copy change, and no change to `VoiceFilterPipeline`. Searches confirm it:

- `grep -rn "ModelPack\|case absent\|case downloading\|case installed" Dspeech DspeechTests` → no model-pack state type anywhere.
- `find DspeechTests -name '*.swift' | xargs grep -l "ModelPack\|absent\|downloading"` → empty. The 29 `@Test`s in `DspeechTests/VoiceFilterTests.swift` are the pre-existing phase-1 suite (SpeakerMatcher, storage round-trip, ATC gate, pipeline-with-unavailable-identifier); none touch a pack state machine.
- Working tree clean; no stash; no untracked Swift (`git status --porcelain --ignored`).
- The landed commit `d8b7534` is authored "AI Office tester-unit" but its content is the docs-writer artifact set; the run note (`docs/run-notes/2026-05-24-local-speaker-model-pack.md:5`) self-declares "Scope: docs / project-memory only. No Swift, pbxproj, tests, or Hermes/cron touched."

Per ADR 0008 itself, the state machine, acquisition UX, identifier swap, and network-deny test are listed under **"Acceptance gates for the next implementation cycle"** (`docs/adr/0008-...:43-55`). So the absence is consistent with the contract's own framing — the contract was authored, the implementation deferred. The mission brief's dependency list (engineer-generic, tester-unit producing code) does not match what landed. **Supervisor should reconcile this** before treating the model-pack feature as in-progress.

## Finding 2 (PASS — privacy/honesty invariants intact): criteria 1–4 hold for what landed

I verified the honesty claims the docs make against live code, and they are true:

- `Dspeech/App/ContentView.swift:15` — default adapter is `VoiceFilterPipeline(identifier: UnavailableLocalSpeakerIdentifier())`. Confirmed.
- `Dspeech/App/LiveTranscriptionViewModel.swift:70` — synthesizes `speaker: .nonPilot(bestPilotScore: 0)` for every segment, with a `// Phase 1 (ADR 0007)` comment naming the deferral. Confirmed honest; no fake decision is fabricated.
- `Dspeech/Core/VoiceFilter/LocalSpeakerIdentifier.swift:43-58` — `enroll`/`classify` on the default adapter `throw LocalSpeakerIdentifierError.modelUnavailable(reason:)`. **Fails closed/honestly** (criterion 2 ✓). `VoiceFilterPipeline.classify` (`VoiceFilterPipeline.swift:169-181`) returns `.nonPilot(bestPilotScore: 0)` only when disabled or no profiles, otherwise delegates to the (throwing) identifier — no silent success path.
- **No fake readiness** (criterion 1 ✓): ADR 0008's state table maps `absent` to "`classify`/`enroll` throw `modelUnavailable`", matching today's behavior; it does not claim any state is reached.
- **No network / auto-download / telemetry / egress added** (criterion 4 ✓): zero code changed, so zero new behavior. The ADR explicitly rejects FluidAudio's silent first-use HuggingFace fetch (`docs/adr/0008-...:60`) and requires an explicit user-initiated `absent → downloading` transition.
- **Privacy badge** (criterion 3 / CLAUDE.md rule 4 ✓): ADR §"Network/privacy contract" item 5 binds `LOCAL`/`CLOUD` to `privacy.allowCloud` and forbids the download from flipping it. No badge code touched.

The eval plan (`docs/eval/...`) is appropriately scoped: it states up front (`:9`) that "It does not assert that any of these gates currently pass — they do not." The fail-open principle (`:50`, "when in doubt, transcribe and surface, never silently hide ATC") is the correct safety posture for an ATC tool and is consistent with `VoiceFilterPipeline.routeBeforeTranscription`'s `.mixed → .transcribe` branch (`VoiceFilterPipeline.swift:134`).

## Finding 3 (NOTE — criteria 5/6/7 are N/A by absence, not by pass)

- Criterion 5 (Swift-6/concurrency coherence): nothing to assess — no Swift landed. The existing `@MainActor final class VoiceFilterPipeline` and `@Observable` VM are unchanged and already coherent.
- Criterion 6 (tests fail on regression of state persistence / capability gating / copy): **cannot hold — there is no state machine, no state-specific copy, and no test for either.** A future regression of model-pack state would be caught by nothing today. This is the single biggest gap and is the headline deliverable of the next cycle (eval checklist item, `docs/eval/...:75`).
- Criterion 7 (build/test evidence from tester-unit concrete enough to trust): the run note states no `xcodebuild` was run because the change is prose-only (`docs/run-notes/...:22-24`). That is the **honest** call for a docs-only diff — but it means there is *no* code evidence this cycle, and the "tester-unit" dependency produced no tests. Markdown cross-links and cited source paths were checked and resolve; I independently re-verified the four cited code anchors above.

## Test / evidence assessment

- Evidence that *exists* is trustworthy: the docs' factual claims about `ContentView.swift:15`, `LiveTranscriptionViewModel.swift:70`, `LocalSpeakerIdentifier.swift`, and the 256-dim embedding all check out against the tree.
- Evidence that is *missing*: any executable proof. No `xcodebuild build test` run this cycle (defensible for prose), but combined with Finding 1 it means the model-pack feature has **zero** test coverage. The eval doc's §5 checklist is entirely unchecked (`[ ]` across the board), which is correct — it is a plan, not a result.
- No CLAUDE.md hard-rule violations, no new network paths, no secrets, no fake AI/transcription. Security posture of the diff: clean (prose only).

## Next highest-leverage slice

Exactly the one ADR 0008 §"Acceptance gates" and the run note already name, and it is now genuinely unblocked by the frozen contract. In dependency order:

1. **`ModelPackState` enum + injected `ModelPackStateStorage`** (mirror the `PrivacySettings` + `PrivacySettingsStorage` template), with the round-trip + crash-recovery test (half-download resolves to `absent`/`failed`, never `installed`) — this closes the criterion-6 gap that this cycle could not.
2. **Capability gating wired to state**: `VoiceFilterPipeline` selects `UnavailableLocalSpeakerIdentifier` unless state is `installed`/`verified`; capability banner + disabled-slot copy become state-specific (replace the static ADR-0007 string). Add the copy-invariant test.
3. **Concrete `FluidAudioSpeakerIdentifier`** swapped in only at `installed`, plus the **network-deny integration test** (the privacy gate, eval §1) and the replay fixtures (eval §2) — green on iPhone 17 Pro / iOS 26.4 sim, with the `xcodebuild` command + output pasted into the run note.

Land the state machine + its tests (steps 1–2) before the backend (step 3): it is the smallest slice that lets a reviewer actually exercise criteria 5–7 against code.

---
Reviewer notes on tests: the pre-existing 29-test voice-filter suite is solid for phase-1 (it asserts the unavailable identifier surfaces capability and that enroll throws). It would **not** catch a regression in model-pack state because that surface does not exist yet. The next cycle's first commit should be the failing state-machine test, per the team's test-first contract.
