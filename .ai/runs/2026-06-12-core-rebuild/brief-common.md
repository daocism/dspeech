# Common worker rules — core-semantics rebuild (2026-06-12)

You are a Codex implementation worker on the Dspeech iOS repo. Claude (tech lead) reviews
every line you produce before it merges. Binding specs: `docs/PLAN-2026-06-12.md` and
`docs/SPEC-2026-06-12-core-semantics-rebuild.md` — read both FIRST, then your brief.

## Hard rules

- Swift 6 strict concurrency, iOS 26+, Xcode 26. Follow existing code style exactly.
- NO comments except single-line `// why:` for non-obvious constraints. No docstrings.
- NO placeholders: no TODO/FIXME markers, no fatalError, no stub bodies, no "coming soon".
- NO scope drift: touch ONLY the files listed under "Files you own" in your brief.
- Fail fast: internal code throws; never return nil/false to mask an error path.
- Tests: Swift Testing (`@Test`, `#expect`, `#require`) in DspeechTests. Mirror the
  existing randomized property-test style (see `UtteranceWindowRouterTests`
  `shouldPreserveRouterInvariantsAcross1000GeneratedCasesWhenSegmentingUtterances` and its
  seeded `private var state: UInt64` SplitMix-style RNG — deterministic seeds, no
  system randomness).
- Names carry meaning; they are grep anchors.
- Privacy: no network code, no audio/transcript egress, nothing leaves the device.

## Build & verify (run before declaring done)

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Dspeech.xcodeproj -scheme Dspeech \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  CODE_SIGNING_ALLOWED=NO build test 2>&1 | tee /tmp/worker-build.log | tail -5
grep -E "TEST (SUCCEEDED|FAILED)" /tmp/worker-build.log
```

Zero warnings policy: the build treats warnings as errors; fix root causes, never suppress.

If your brief assigns pbxproj IDs: register new files in `Dspeech.xcodeproj/project.pbxproj`
by appending entries that EXACTLY mirror the style of existing entries (PBXBuildFile +
PBXFileReference + group children + Sources build phase). Never renumber or touch existing
IDs.

## Contract types (already on the branch — do not redefine, do not modify)

- `Dspeech/Core/Models/Transmission.swift`: `Transmission`, `TransmissionClassification`
  (`.displayed(TransmissionDisplayReason)` / `.filtered(TransmissionFilterReason)`),
  `TransmissionUpdate` (`.opened/.updated/.closed`).
- `TranscriptSegment.isInterimRestartCommit: Bool` (new flag, Codable-backward-compatible).
- `LiveTranscriptionEvent.taskRestart` (new case).

## Deliverable

Work directly in your assigned worktree on the checked-out branch. When done: run the
verify commands, then `git add <your files> && git commit` (conventional commits,
`Co-Authored-By: Codex GPT-5.5 <noreply@openai.com>` footer). Print a short summary:
what you built, test names added, anything you deviated on and why.
