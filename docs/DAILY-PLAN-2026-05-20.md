# Dspeech — Daily Plan 2026-05-20 (tech-lead view)

## Status snapshot
- **Branch**: `feat/mvp-completion-2026-05-19` pushed to `origin`. PR url: `https://github.com/daocism/dspeech/pull/new/feat/mvp-completion-2026-05-19`
- **HEAD**: `6618013 docs(adr): 0007 defer TranslationSessionPort; 0008 trim-contract authoritative`
- **Open blockers from W6 round 3 ESCALATED** (review.md):
  - ✅ BLOCK-1 RESOLVED (settings-button hit-point, commit `56f261c`)
  - 🟡 BLOCK-2 in flight — test files landed (commit `5b624dd`), implementation must satisfy 9 frozen XCUI contracts → W4b-round-4 dispatch
  - ✅ MAJOR-3 ACCEPTED as deferred via ADR-0007
  - 🟡 MAJOR-4 in flight — 1-line gate, dispatched together with W4b-round-4
  - ✅ MAJOR-5 ACCEPTED via ADR-0008 with mandatory implementation amendment in W4b-round-4
- **MINOR-6/7/8**: carried forward to post-MVP backlog (in NOTION-TASKS.md)

## Today's critical path (autopilot)
- **W4b-round-4** implementer — fix 9 RED XCUI tests + MAJOR-4 gate + ADR-0008 impl amendment
- **W7 verifier** — 8-gate verification (build/test/grep/screenshots/privacy-LOCAL boot)
- **W8 design-review** — Gemini 3.1 Pro review of W7 screenshots
- **W9 docs** — MISSION_REPORT-2026-05-20.md, DEVICE-VERIFICATION-iPhone17ProMax.md, NOTION-TASKS.md, CHANGELOG bump
- **Push** — final push to `origin/feat/mvp-completion-2026-05-19`

## Today's hardening lane (queued in NOTION-TASKS.md, autopilot picks up after critical path)
- Threading-model audit → adopt Sendable conformance findings from `docs/threading-model-audit.md`
- Error taxonomy adoption → align Core/* on the unified taxonomy in `docs/error-taxonomy.md`
- Cold-start instrumentation → wire signposts per `docs/ops/cold-start-instrumentation-spec.md`
- Privacy manifest landing → add `PrivacyInfo.xcprivacy` per `docs/receive-only-claim-evidence-2026-05-20.md`
- Snapshot tests → scaffold per `docs/snapshot-tests-design.md`
- Localization migration → xcstrings catalog per `docs/localization-audit-2026-05-19.md`

## Today's polish lane (queued in NOTION-TASKS.md)
- Liquid Glass design pass — header chip, control bar, SettingsSheet rows, FirstRunView cards, AboutView attributions
- WCAG / Apple HIG accessibility — Reduce Transparency fallback, Dynamic Type, contrast audit
- Gemini design-review iteration loop per screen

## Blocker (auth)
Headless `claude -p` from this orchestrator (ubuntu-vm via SSH) hits the mac24 Keychain lock — the OAuth token from the GUI re-login is **GUI-session-only**. Two clean resolutions:

**Option A (recommended, one-time action from you)**:
On mac24, open **Terminal.app in the GUI** (not via SSH). Run:
```
cd ~/projects/dspeech-ios
nohup bash .agent-prompts/workday-pilot.sh > /tmp/pilot.log 2>&1 &
disown
```
Then minimize the Terminal window. The pilot runs in your GUI-session context where the Keychain is unlocked. `claude -p` will work for every wave. The watchdog can also be launched the same way if you want passive monitoring:
```
nohup bash .agent-prompts/watchdog-v3.sh > /tmp/watchdog.log 2>&1 &
disown
```

**Option B (permanent, no GUI action required)**:
Add an Anthropic API key to mac24 so headless SSH never needs the Keychain. From your `daocism.1password.com` UI, create a new pay-as-you-go API key (separate from your Max subscription — they coexist), then save it to vault `MyInfra-Active` as item name `anthropic-api-key-mac24` with field `key` = the api key. The next orchestration session reads it via 1Password service account and writes it into `~/.claude/settings.json` env block on mac24.

## What you do today (≤2 minutes)
1. Open Terminal.app on mac24 (Cmd+Space → "Terminal")
2. Paste the Option A command block above
3. Close the Terminal window (don't quit; just close the window) — the `nohup` + `disown` keeps it running
4. Walk away. When you return: check `docs/MISSION_REPORT-2026-05-20.md` on GitHub for the final report, and `docs/DEVICE-VERIFICATION-iPhone17ProMax.md` for the device-gate walkthrough on your iPhone 17 Pro Max.

## What I do next session
- Re-snap status from `docs/MISSION_REPORT-2026-05-20.md` or `docs/NEEDS-HUMAN.md`
- If APPROVED → merge to main, hand off F1–F8 device-gate walkthrough
- If still blocked → triage finding, dispatch targeted remediation
- Then begin **hardening lane** (`hardening/2026-05-20`) and **polish lane** (`polish/glassmorphism-2026-05-20`) per NOTION-TASKS.md
