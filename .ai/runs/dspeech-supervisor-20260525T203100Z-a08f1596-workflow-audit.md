# Workflow audit — supervisor run `dspeech-supervisor-20260525T203100Z-a08f1596`

Role: docs-writer (ubuntu-vm worktree; no mac24 Claude, no SSH needed for this audit)
Date: 2026-05-25
Branch audited: `feat/local-pilot-voice-filter`
Subject: builder run `dspeech-builder-20260525T190042Z-c2188fe3` finalized **Blocked**.

## Verdict

The `Blocked` finalizer status for `dspeech-builder-20260525T190042Z-c2188fe3` is a
**workflow false-negative**, not a product or test failure. The product code and the
test evidence for the slice are landed, pushed, and green. The only thing missing is
one worker's *artifact*, which was lost to a transient Claude API `500` mid-turn —
after that worker had already confirmed the checkout was clean and was one step from
writing its file.

## Evidence table

| Signal | Value | Source |
| --- | --- | --- |
| Branch head before dispatch | `89495cc docs(run-notes): tester-unit verification … 2d2da3e` | supervisor input; `git log` in this worktree |
| Tested SHA | `2d2da3e1c474c6c24ca32361478cca811e71e567` (canonical tip of `origin/feat/local-pilot-voice-filter` at test time) | `…-c2188fe3-tester-unit.md` |
| Test platform | mac24, iPhone 17 Pro / iOS 26.4, `-only-testing:DspeechTests`, `CODE_SIGNING_ALLOWED=NO` | `…-c2188fe3-tester-unit.md` |
| Test result | `** TEST SUCCEEDED **`, 184 passed / 0 failed, green across 4 consecutive invocations | `…-c2188fe3-tester-unit.md` |
| Speaker-identifier suites | `FluidAudioBackendBuilderTests`, `LocalSpeakerIdentifierFactoryTests`, `VoiceFilterPipelineTests`, `SpeechAudioBufferGateTests`, `ModelPackStateStorageTests` — all green | `…-c2188fe3-tester-unit.md` |
| Tester artifact commit | `89495cc` (pushed) | branch head |
| Reconciliation outcome | `a8a643d` strict ancestor of origin `4fe4a44`; clean fast-forward, no `git reset --hard`, no dirty/staged state to recover; doc-only | `…-c2188fe3-canonical-recovery.md` |
| qa-manual checkout check | "Canonical checkout is now pristine: clean working tree, on `feat/local-pilot-voice-filter`, 0/0 divergence from origin" | `streams/qa-manual.jsonl` |
| qa-manual existing-artifact check | tester-unit + canonical-recovery artifacts present; identity `AI Office tester-unit`; remote `git@github.com:daocism/dspeech.git`; push-capable | `streams/qa-manual.jsonl` tool_result |
| qa-manual terminal event | `API Error: 500 Internal server error`, `api_error_status:500`, `terminal_reason:"completed"`, `num_turns:20` | `streams/qa-manual.jsonl` result record |
| qa-manual exit | `1` → `worker_blocked` emitted | `streams/qa-manual.exit`, `qa-manual.jsonl` tail |

## Why Blocked is a false-negative

1. The finalizer marked the run `Blocked` **solely** because `qa-manual` exited `rc=1`.
2. `qa-manual`'s own stream shows it had completed its substantive work: it verified
   the canonical checkout was pristine (clean tree, on-branch, 0/0 divergence), confirmed
   the prior worker artifacts existed, confirmed git identity and push capability — and
   its next stated action was "write and commit the QA artifact."
3. Before that write executed, the session hit a Claude API `500 Internal server error`
   (`req_011CbPqF8VkYVmgdFgh5kVzc`). The `result` record carries `is_error:true` with
   `api_error_status:500` — a server-side fault, not an assertion failure, build break,
   or QA-rejection. `rc=1` is the harness surfacing that API error, nothing more.
4. The product/test substance the run existed to verify is independently recorded and
   green: tester-unit ran the full `DspeechTests` suite at `2d2da3e` → `** TEST SUCCEEDED **`,
   184/184. That artifact is committed at `89495cc` and pushed.

So: code landed, tests green, branch coherent — only the QA *narrative file* is missing,
and it is missing because of an upstream API outage, not because QA found a defect. This
exactly mirrors the false-negative pattern already on record for run
`dspeech-builder-20260524T190024Z-0f54bfce` (finalizer said Blocked while the code had
already landed green); see `.ai/project-state.md`.

## Notion `NOT_FOUND` is a sync / read-model issue

The Notion connector returned `NOT_FOUND` for task `369dfa2b-7893-814c-be7e-e7cea26486a6`
to this supervisor. Per the binding decision in `docs/ai-kb/current-context.md`, **Notion
is a read model only** — the repo (`.ai/` + `docs/ai-kb/` + commit SHAs) is canonical for
AI project memory. A `NOT_FOUND` from the connector therefore reflects connector
reachability / read-model staleness from the run environment, **not** lost project state
and **not** a reason to treat the run as blocked. No duplicate task was created.

## Current git state (clean)

```
HEAD (detached) @ 89495cc — canonical tip of origin/feat/local-pilot-voice-filter
working tree: clean (nothing to commit)
divergence from origin/feat/local-pilot-voice-filter: 0 ahead / 0 behind
remote: git@github.com:daocism/dspeech.git
```

The branch is exactly the pushed, tested state. There is nothing to reconcile.

## Next product priority (unchanged, restated for the record)

In order — all buildable now, none gated on architecture approval:

1. **Pre-ASR classifier hardening before production discard.** The offline FluidAudio
   `LocalSpeakerIdentifier` (`FluidAudioSpeakerIdentifier` + `FluidAudioBackendBuilder`)
   is landed behind the installed model-pack gate with zero audio egress, but a default
   build still fails open to `UnavailableLocalSpeakerIdentifier`. Before discard goes
   live in production: move classification off `@MainActor` with FIFO append ordering
   (reviewer W1), make discard utterance-aware rather than raw-buffer-level (reviewer W2),
   and add the ADR 0008 network-deny integration test.
2. **Replay / source-audio validation kit.** A fixture harness that feeds recorded ATC
   source audio through the ASR + filter pipeline so transcription/filter quality is
   regression-testable without aircraft hardware.
3. **App Store / TestFlight readiness.** Signing, TestFlight build, privacy nutrition
   labels, on-device/offline messaging, export compliance — only after 1 + 2 yield a real
   installable local build.

## True user-side blockers (not approval theater)

These are the only items that genuinely gate progress; everything else is buildable now
without Andrei's sign-off:

- Apple Developer / TestFlight credentials (device builds + App Store).
- A physical iPhone + real external ATC audio input hardware (device smoke of the
  route-health chip / Start gate / external-loss pause).
- Real-world ATC sample audio (replay-kit fixtures + voice-filter tuning).
- mac24 Claude login — **only if** a future run needs direct mac24 AI workers rather than
  ubuntu-vm→mac24 SSH for deterministic git/xcodebuild/simctl.

## Recommended finalizer disposition

Treat `dspeech-builder-20260525T190042Z-c2188fe3` as **Done with a missing QA artifact**:
the slice it covered (offline FluidAudio speaker identifier behind the installed model-pack
gate) is landed at `2d2da3e`, verified green (184/184), and pushed at `89495cc`. The
`Blocked` flag was driven by a transient API `500` that killed `qa-manual` after its clean
checkout check, not by any product, build, or test defect. No code change is warranted by
this audit.
