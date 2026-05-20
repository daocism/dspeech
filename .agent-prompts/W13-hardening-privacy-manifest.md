# W13 — Hardening: PrivacyInfo.xcprivacy manifest

You are a **privacy-compliance hardening implementer**. Branch:
`hardening/privacy-manifest-2026-05-20` from `feat/mvp-completion-2026-05-19`.

## Mission
Author `Dspeech/PrivacyInfo.xcprivacy` per
`docs/receive-only-claim-evidence-2026-05-20.md`. Declare exact reasons for
every required-reason API the app uses (UserDefaults, file timestamps, etc.).
NSPrivacyTracking = false. NSPrivacyCollectedDataTypes empty (no analytics).
NSPrivacyAccessedAPITypes: declare each API with reason code per Apple's
allow-list. Add the file to the Dspeech app target in `project.pbxproj`.

## Pre-flight
1. Baseline branch + green suite.
2. Re-read App Store Privacy manifest documentation via Context7 (subsystem:
   "App Privacy Configuration / PrivacyInfo.xcprivacy") so the reason codes
   match the current allow-list.

## Work
- Author the plist with proper schema.
- Pbxproj wiring: add file ref + build-file entry in the **app target**
  Resources phase. `plutil -lint` must pass.
- Re-check by grep: `UserDefaults`, `FileManager.attributesOfItem`,
  `Date()`, `MachAbsoluteTime`, etc. → ensure each is covered by a reason code.

## Verification gates
1. `xcodebuild build test` = **PASS 88/0/0**.
2. `plutil -lint Dspeech/PrivacyInfo.xcprivacy` = OK.
3. `xcodebuild` archive (`-archivePath /tmp/Dspeech.xcarchive`) succeeds —
   archive flow validates the manifest is bundled.
4. Manifest contents reviewed against latest Apple required-reason list
   (cite Apple doc URL in commit body).

## Output
- Atomic commits + push.
- `docs/handoff.md` `## W13 hardening-privacy-manifest — 2026-05-20` with
  fields: `manifest_path`, `apis_declared` (list), `archive_ok`, `ready_for_reviewer: yes`.
- `docs/NOTION-TASKS.md` rows for any third-party SDK manifest gap (if added later).

## Anti-AI guards
- Do not declare APIs the app does not actually use.
- Do not check in stub / template values.
- Context7 every reason code against Apple's published list.
