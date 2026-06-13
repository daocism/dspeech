# W7 — WhisperKit model installer + engine picker settings

Read brief-common.md first. Same rules. Spec §5.2: in-app model download/manage UX
following the existing voice-pack acquisition patterns; engine picker in Settings;
default engine stays apple (ADR 0011 — read it).

## Files you own

- `Dspeech/Core/ASR/WhisperKitModelInstaller.swift` (new)
- `Dspeech/Core/Settings/RecognitionSettings.swift` (extend: persisted engine choice)
- `Dspeech/App/SettingsView.swift` (engine picker section + model download/delete UI)
- `DspeechTests/WhisperKitModelInstallerTests.swift` (new)
- `DspeechTests/RecognitionSettingsTests.swift` (extend)
- pbxproj IDs: installer fileRef `A00000000000000000000954` + buildFile `...0955`
  (app Sources `...0018`, group ASR `...0009`); installer tests fileRef `...0956` +
  buildFile `...0957` (test Sources `...0021`, group `...0010`).

## Engine choice setting

Read `Dspeech/Core/Settings/RecognitionSettings.swift` FIRST and mirror its exact
persistence pattern (storage protocol + UserDefaults impl + round-trip tests).
Add:

```swift
enum TranscriptionEngineChoice: String, Codable, Sendable, CaseIterable {
  case apple
  case whisperKit
}
```

persisted with default `.apple`. The picker UI: a Settings section "Recognition
engine" with a `Picker` (accessibilityIdentifier `recognition-engine-picker`),
plus — ONLY when whisperKit is selected or its model is installed — the model
status row (state, size, download button with progress, delete button; ids
`whisperkit-model-download`, `whisperkit-model-delete`, `whisperkit-model-status`).
Selecting whisperKit with NO installed model must show an inline hint that the
model download is required and the app falls back to Apple until installed —
never a dead toggle (no fake-AI rule). Localize new strings in Localizable.xcstrings
for en (source) — other locales fall back; list added keys in your summary.

## Model installer (mirror `SpeakerModelPackInstaller` — read it FIRST, same
state machine + storage discipline)

```swift
@MainActor
@Observable
final class WhisperKitModelInstaller { ... }
```

- States: absent / downloading(progress) / installed(WhisperKitInstalledModel) /
  failed(reason) — reuse the ModelPackState pattern (do NOT touch ModelPackState
  itself; define whisperkit-scoped types).
- Model: `large-v3-v20240930_626MB` from HF repo `argmaxinc/whisperkit-coreml`,
  PINNED revision: resolve the repo's current main commit SHA and hard-code it as
  `pinnedRevision` with a `// why:` (supply-chain rule — never download floating
  main). Download via the same HF download approach SpeakerModelPackInstaller uses
  (per-file URLSession download into Application Support relative container path,
  backup-excluded, atomic move; checksum: record SHA256 of each downloaded file in
  the installed manifest at install time).
- The app's WhisperKit engine (separate work package) will load ONLY from the
  installed local folder (`modelFolder:` + `download: false`) — expose
  `var installedModelFolderURL: URL?`.
- Local-only after download; downloading requires explicit user tap (never auto).
- Disk-full → failed(reason) taxonomy like the voice pack; delete removes folder +
  manifest and returns to absent.
- Tests: state machine transitions with a fake downloader (no network in tests),
  round-trip of installed manifest, delete path, disk-full taxonomy. NO real
  network in unit tests.

DO NOT add the WhisperKit SPM dependency to the app project and DO NOT import
WhisperKit anywhere in the app target — the installer is pure
Foundation/URLSession; the engine adapter is a separate package with its own
integration step. (The CLI harness already depends on WhisperKit — untouched.)

Verify: full build test green, zero warnings. Commit.
