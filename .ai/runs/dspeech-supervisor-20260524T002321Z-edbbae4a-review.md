# Dspeech supervisor review — 2026-05-24

Run: `dspeech-supervisor-20260524T002321Z-edbbae4a`
Role: `reviewer` (supervisor audit)
Repo audited: `/home/user/projects/dspeech` @ `b671f74` (branch `feat/local-pilot-voice-filter`)
Method: read-only code + artifact audit on ubuntu-vm. No Xcode on this host; build/test claims attributed to their mac24 source artifacts, never asserted first-hand.

## Verdict

**State is HONEST. Branch is shippable as a Phase-1 layer. One verification gap + recurring workflow bugs remain.**

- The current branch does **not** overclaim. The headline "local pilot voice filter" is openly surfaced as *unavailable* in the UI (enrollment disabled, capability banner shown, ADR 0007 cited), and the code comments state Phase 1 has no real classifier. This is a truthful stub, not a §4 silent-failure lie.
- The route-health UX that the prior reviewer (`8ff9dfb0`) correctly rejected as "not delivered" **is now genuinely wired** in `b671f74` (`CaptureCoordinator` + `ContentView`), with the `.lost`→`engine.stop()` behavior that makes the old banner copy true. The earlier REQUEST_CHANGES is resolved.
- **Open honesty gap:** the green xcodebuild evidence on record is at `bdef438`/`5235e0b` (105 unit tests, route-health layer). The UX-wiring commit `b671f74` and its 9 new `CaptureCoordinatorTests` have **no** post-commit mac24 build/test artifact. Do not market the UX slice as verified until that run exists.
- **Workflow is still buggy.** The `base_repo` defect is not fixed — it is present in *this very supervisor run*. `b671f74` was authored by role `tester-unit` (a feat() production commit = role-scope violation). The `8ff9dfb0` finalizer reported `Blocked` and wrote `Blocked` to Notion while a useful commit landed in the same window.

## Verified Evidence

All items below were checked directly; file:line and run-log paths cited.

| # | Claim | Verified result |
|---|-------|-----------------|
| E1 | Route-health UX wired into capture UI | **TRUE.** `Dspeech/App/CaptureCoordinator.swift:24` `canStart`, `:36-43` `start()` gates on `routeMonitor.blocksStart`, `:57-62` `handleRouteEvent` calls `live.stop()` on `.lost` while listening. `Dspeech/App/ContentView.swift` consumes it: `route-banner` (`:96`), `route-health-chip` (`:294`), Start gated `startDisabled = !coordinator.canStart` (`:137`). |
| E2 | `b671f74` "surface route health in capture UI" exists/pushed | **TRUE.** `git show -s b671f74` → authored `2026-05-23 21:13:41 +0200`, author `AI Office tester-unit`. Branch HEAD, pushed (worktree clean, up to date with origin). |
| E3 | NSLock-in-async compile blocker fixed | **TRUE.** `Dspeech/Core/Audio/AudioSessionRouting.swift:47-48` `requestRecordPermission() async -> Bool` now returns `_permissionGranted` directly (a `private let`, `:15`); no lock in async context. Sync methods still lock (valid). Matches `e6e6083` claim. |
| E4 | pbxproj test-target Release config name corrected | **TRUE.** `Dspeech.xcodeproj/project.pbxproj:141` `A00000000000000000000040 /* Release */` now `name = Release` (was `name = Debug` per the blocked report). All 8 configs now correctly named. |
| E5 | Local speaker model is a stub | **TRUE.** `Dspeech/Core/VoiceFilter/LocalSpeakerIdentifier.swift:27` `UnavailableLocalSpeakerIdentifier` throws `.modelUnavailable` on both `enroll` and `classify`. It is the **only** concrete conformer; `ContentView.swift:15` wires it unconditionally (`?? VoiceFilterPipeline(identifier: UnavailableLocalSpeakerIdentifier())`). |
| E6 | Callsign gate is post-ASR, not pre-ASR pilot suppression | **TRUE.** `ATCTranscriptGate.evaluate(text:speaker:timestamp:)` operates on transcript `text` (`ATCTranscriptGate.swift:30-63`). `LiveTranscriptionViewModel.append(segment:)` feeds `speaker: .nonPilot(bestPilotScore: 0)` hard-coded (`:70`), with an explicit comment that Phase 1 has no classifier (`:65-67`). Pre-ASR `routeBeforeTranscription` exists (`VoiceFilterPipeline.swift:124`) but is inert: profiles can never be enrolled (enroll throws), so it always returns `.transcribe(.noPilotProfile)`. |
| E7 | Stub is honestly surfaced to user | **TRUE.** `ContentView.swift:419-449` renders `voicefilter-capability-banner` "Слот пилота недоступен", disables enrollment buttons (`.disabled(true)`, `:441`), copy "Запись голоса появится после установки модели." Footer cites ADR 0007. No false "filter active" claim. |
| E8 | Unit tests green on mac24 | **TRUE at `bdef438`/`5235e0b` only.** `.ai/runs/2026-05-23-route-health/tester-unit.md:134-137`: 105/105 unit, 59/59 targeted, on iPhone 17 / iOS 26.4. `mrdao-autopilot-fix.md` re-verified from a clean clone (Debug build+test + Release build). **Not** re-run at `b671f74`. |
| E9 | `b671f74` UX tests exist | **TRUE (authored), UNVERIFIED (executed).** `DspeechTests/CaptureCoordinatorTests.swift` has 9 `@Test`s incl. `startBlockedWhenNoInput`, `oldDeviceUnavailableExternalToBuiltInStopsAndShowsNotice`, `oldDeviceUnavailableWhenIdleDoesNotCallStop`, `routeBannerNilForSilentNotice`, `blockedMessageAvoidsForbiddenPhrases`. No xcodebuild artifact covers them. |

## Workflow Bugs Found

Verified from `team_plan.json` / `team-dispatch.log` / `task.md` under `MyInfra/tmp/ai-office-runs/`.

| # | Severity | Bug | Evidence |
|---|----------|-----|----------|
| W1 | **HIGH (recurring, live)** | Top-level `base_repo` points at MyInfra, so every worker (incl. this reviewer) gets a **MyInfra git worktree**, not a dspeech one. All dspeech edits land in the shared canonical checkout `/home/user/projects/dspeech`. | `dspeech-supervisor-20260524T002321Z-edbbae4a/team_plan.json:43` `"base_repo": "/home/user/projects/MyInfra"` — **this run**. Identical in `8ff9dfb0`, `53ab81d7`, `4fea767f`. My assigned worktree `wt-reviewer` → `git remote` = `daocism/MyInfra.git`. |
| W2 | **HIGH** | Planner emitted a plan that violates its own written constraint. `task.md` for `8ff9dfb0` already states (lines 20-22) "must NOT assign workers to mac24" and "`base_repo` MUST be `/home/user/projects/dspeech`" — yet the same run's `team_plan.json:43` set MyInfra. The rule is documented but not enforced at plan-generation. | `8ff9dfb0/task.md:20-22` vs `8ff9dfb0/team_plan.json:43`. |
| W3 | **HIGH** | Workers assigned to **host mac24 while mac24 Claude is logged out** (`loggedIn=false`). | `4fea767f/team_plan.json:16` `engineer-frontend host=mac24`, `:26` `tester-unit host=mac24`. Constraint later codified in `8ff9dfb0/task.md:20`. |
| W4 | **MEDIUM** | Run used role `engineer-ios`, whose registry `host_preference` rewrites the host to mac24 — the role the corrected rule forbids. | `53ab81d7/team_plan.json:7` `"role": "engineer-ios"`. |
| W5 | **MEDIUM** | Role-scope violation: production feature commit authored by `tester-unit`. `b671f74 feat(audio): surface route health in capture UI` (SwiftUI + coordinator) was authored by `AI Office tester-unit`. A tester writing `feat()` production code breaks the distinct-persona contract. (Also note earlier `5235e0b test(audio):` carried 5 production Swift files under a `test(` commit — same class of mixing.) | `git show -s b671f74` author line; prior reviewer finding #4 in `route-health-ux.md:29`. |
| W6 | **MEDIUM** | False `Blocked` finalization. `8ff9dfb0` finalizer logged `status=Blocked pr_url=none` and pushed `Blocked` to Notion, but `b671f74` (the useful UX commit) was authored inside the same run window (19:13 UTC; run started 19:00 UTC). Root cause is ordering, not just budget: the reviewer handoff ("no UX") was written *before* tester-unit wired the UX in `b671f74`, and the finalizer aggregated the stale reviewer verdict. | `8ff9dfb0/team-dispatch.log:9-10`; `route-health-ux.md` reviewer verdict vs `b671f74` timestamp. |

## Safe Fixes Confirmed

These are landed and verified safe to keep:

- **Route-health start-gate + loss-stop wiring** (`CaptureCoordinator`, `ContentView`). Pure `AVAudioSession` introspection behind the `AudioSessionRouting` protocol; zero network/egress (confirmed: no `URLSession`/`Network.framework`/`NWPathMonitor`/`http(s)://` in route-health files per `tester-unit.md:105`). The `.lost`→`stop()` makes the "Запись приостановлена" banner copy honest.
- **Swift-6 async-lock fix** (`e6e6083`) — minimal and correct (`_permissionGranted` is immutable, lock was unnecessary).
- **pbxproj Release config name** (`e6e6083`) — restores unambiguous Debug/Release resolution.
- **Honest capability surfacing** — disabled enrollment + capability banner is the right Phase-1 UX; it neither lies nor blocks future model wiring.
- **Copy guards** — `displayCopyAvoidsCertifiedLanguage` / `bannerCopyAvoidsCertifiedLanguage` / `blockedMessageAvoidsForbiddenPhrases` forbid `certif/guarantee/radio link/tower link/faa/easa`. Appropriate for an uncertified ATC aid.

## Product Risks

Against the north star (reliable ATC-only transcript, local/offline iOS, future radio/Bluetooth input, App Store readiness):

1. **R1 — The headline feature is inert at runtime (highest).** "Local pilot voice filter" is the branch name, but no real on-device speaker model exists. `UnavailableLocalSpeakerIdentifier` is the only conformer; enrollment is impossible, so pilot suppression never fires. Today the app is an *on-device ASR + post-ASR callsign text gate*, not a voice filter. Honest, but the core value prop is unbuilt.
2. **R2 — Callsign gate is post-ASR.** The final pre-ASR pilot-suppression path (discard pilot audio before transcription) depends entirely on R1's model. Until then, pilot speech *is* transcribed, then suppressed by text rules only when speaker is known — and speaker is hard-coded `.nonPilot`.
3. **R3 — `b671f74` UX slice is unverified on device/simulator.** The compile-and-test history stops at `bdef438`. SwiftUI `@MainActor` async wiring + 9 new tests are exactly the surface that can break a Swift-6 build. No artifact proves it green.
4. **R4 — No replay/source-audio validation kit.** Every test uses synthetic `PortSnapshot`/fakes. There is no way to regression-test transcription quality against canonical ATC source audio without aircraft hardware — so ASR/filter regressions are invisible to CI.
5. **R5 — `bluetoothLE`/`airPlay` classified as `.suitableExternal`** on unvalidated assumptions (pinned, not confirmed). AirPlay is an output transport; treating it as a capture source is questionable for ATC. Needs real-hardware confirmation before it misleads a pilot about input quality.
6. **R6 — App Store / TestFlight readiness not started.** No signing, no TestFlight build, no privacy-nutrition/export-compliance work. Premature until R1+R3 give a real installable local build.

## Next Builder Cycle

Recommended priority (evidence supports the mission's suggested order):

1. **Replace the `UnavailableLocalSpeakerIdentifier` stub with a concrete local model-pack boundary** (resolves R1/R2). Deliver a *real boundary + tests*, not a memo:
   - A `LocalSpeakerIdentifier` conformer backed by an on-device embedding model (FluidAudio is the named Phase-2 candidate — `LiveTranscriptionViewModel.swift:67`), gated behind a model-pack that the app can **download/import/verify on-device with zero audio egress**.
   - UX to download/import/select the model, replacing the disabled enrollment buttons; flip `VoiceFilterCapability` to `.ready` only when a verified model is present.
   - If model selection needs research, dispatch `researcher-docs`/`researcher-web` + `swiftui-implementer` + `tester-unit` — but the cycle's output must be a working boundary with enroll/classify tests, not a research note.
   - **Wire the pre-ASR path:** once classify is real, replace the hard-coded `.nonPilot` in `LiveTranscriptionViewModel.append` and route through `routeBeforeTranscription` so pilot audio is discarded *before* transcription.
2. **Add a replay/source-audio validation route** (resolves R4): a fixture harness that feeds recorded ATC source audio through the ASR+filter pipeline so source audio stays canonical and regressions are testable without aircraft hardware. This also unblocks honest quality claims.
3. **App Store / TestFlight readiness** (R6) — only after 1+2 yield a real installable local build (signing, TestFlight, privacy nutrition, export compliance).

**Process fixes to land before/with the next code cycle (do not skip):**
- Fix W1 at the plan generator: top-level `base_repo` for dspeech work MUST be `/home/user/projects/dspeech`; workers must get dspeech worktrees. Until fixed, every "landed" claim is suspect because edits hit the shared checkout.
- Enforce W2/W3/W4 in plan validation: reject any plan assigning a worker to mac24 while mac24 Claude is logged out, or using `engineer-ios`/any role whose `host_preference` rewrites to mac24.
- Fix W6: finalizer must read the actual branch HEAD / pushed commits at finalize time, not only the earliest-written worker handoff, before declaring `Blocked`.
- **Run a verification cycle on `b671f74`** (deterministic mac24 `xcodebuild build test` from a clean clone) to close R3 before any new feature work is layered on top.

## Real User-Side Blockers

These genuinely require Andrei; do **not** create approval tasks for anything else:

- **Apple Developer / TestFlight credentials** — required for step 3 (App Store readiness). Not needed before then.
- **Physical iPhone + external ATC audio source** — required for the residual device smoke test (`tester-unit.md:146-148`): route-health chip on plug/unplug, Start-disabled-with-reason, mid-capture unplug actually pausing ASR. Simulator cannot exercise real route changes.
- **Real-world ATC sample/source audio** — required to build the R4 replay fixture and to validate the R1 speaker model on real cockpit audio (incl. R5 BLE/AirPlay capture confirmation).
- **mac24 Claude subscription login** — only if the team decides to assign direct AI workers to mac24 (currently `loggedIn=false`; the workaround is ubuntu-vm workers SSHing to mac24 for deterministic `xcodebuild` only).

---

### Notion

No Notion update was performed by this reviewer. The `8ff9dfb0` finalizer's own log shows it wrote `status=Blocked` to page `369dfa2b-7893-811d-9619-d01a2b922ad9` (`8ff9dfb0/team-dispatch.log:10`); that stale `Blocked` should be reconciled against current branch reality (`b671f74` landed) by whoever owns the Notion sync — this audit does not touch it.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
