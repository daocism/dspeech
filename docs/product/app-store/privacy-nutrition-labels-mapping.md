# App Store privacy nutrition labels mapping

Status: staged for App Store Connect entry. This document is a worksheet; it
does not publish privacy answers and it does not update App Store Connect.

## Product privacy position

Dspeech's target App Store privacy label is **Data Not Collected** for the
current MVP build, provided the submitted binary remains aligned with ADR 0002
and the release manager resolves the model-pack acquisition caveat below:

- no account creation;
- no analytics, ads, tracking SDKs, or outbound support channel;
- no uploaded audio, transcript, voice sample, callsign, route metadata, or
  model-pack path;
- Apple Speech and microphone permissions are used for local app functionality;
- model-pack acquisition, when enabled, downloads model bytes only after an
  explicit user action and does not upload audio, transcripts, voice samples,
  callsigns, or route metadata.

Apple's App Privacy page says App Store Connect asks whether the developer or
third-party partners collect data from the app; when the answer is no, no
further data-type questionnaire is required. If a third-party model host retains
request diagnostics from the model-pack download, the answer may need to change
for that submitted build. Source:
https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/

## Current manifest state

The current working-tree candidate at `Dspeech/PrivacyInfo.xcprivacy` declares:

- `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1`;
- empty `NSPrivacyCollectedDataTypes`;
- `NSPrivacyTracking = false`;
- empty `NSPrivacyTrackingDomains`.

This worksheet maps that declared API to App Store privacy-nutrition answers. If
the submitted archive does not bundle this manifest, privacy-manifest readiness
is blocked before upload.

Apple source for manifest separation:
https://developer.apple.com/documentation/bundleresources/privacy_manifest_files

## Required-reason API mapping

| Privacy manifest API category | Current declaration | Repo evidence | App Store privacy label mapping | Not Collected justification | Release note |
|---|---:|---|---|---|---|
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` in the working-tree manifest candidate | `Dspeech/Core/Settings/PrivacySettings.swift`, `Dspeech/Core/VoiceFilter/VoiceFilterStorage.swift`, `Dspeech/Core/VoiceFilter/ModelPackState.swift` store local privacy, voice-filter, callsign, and model-pack state in app-scoped defaults. | No App Store data category collected. | Values stay in the app sandbox and are used only to restore local app state. They are not sent to Dspeech, Apple beyond normal OS services, or third-party analytics. | Bundle the manifest in the submitted archive. Apple's UserDefaults docs state this API requires a privacy manifest reason: https://developer.apple.com/documentation/foundation/userdefaults |
| FluidAudio SDK privacy manifest and tracking audit | Not declared in this app manifest | `Dspeech.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` pins `FluidAudio` `0.14.7` from `https://github.com/FluidInference/FluidAudio.git`. | Block App Store "Data Not Collected" publication until the processed archive confirms no SDK-collected data, no tracking domains, and no additional required-reason APIs beyond this worksheet. | Dspeech does not intentionally collect audio, transcripts, voice samples, route metadata, or identifiers through FluidAudio. The remaining question is the SDK/archive disclosure surface, not app product intent. | AUDITED 2026-07-02 (feat/night-polish-20260702): a fresh unsigned archive was scanned for every embedded `.xcprivacy`; the ONLY manifest in the archive is the app's own (statically linked FluidAudio 0.15.4 / WhisperKit 1.0.0 ship no SDK manifest bundles): tracking=false, tracking domains empty, collected-data empty, required-reason APIs exactly this worksheet's three. Note: Xcode 26 removed the `xcrun privacyreport` CLI — the equivalent manifest aggregation was performed directly; re-attach an Organizer-generated report at release time if Apple's tooling returns. North-star §4 satisfied for the current dependency set. |
| File-system model-pack checks | Missing | `Dspeech/Core/VoiceFilter/SpeakerModelPackInstaller.swift` locates and verifies local model files with `FileManager`, file existence checks, directory enumeration, and file-size resource values. | No App Store data category collected. | File paths and file sizes are local operational state for validating a user-installed local model pack; they are not collected or transmitted. | Run an archive privacy scan after adding the manifest. If Xcode or App Store Connect flags a required-reason file API, add the exact Apple category/reason from the current required-reason list. |
| Explicit model-pack download | Not a privacy-manifest required-reason API entry | `SpeakerModelPackInstaller.install` calls `DiarizerModels.downloadIfNeeded` and the source is `FluidInference/speaker-diarization-coreml`. | Conditional. Target is Not Collected only if the submitted build either keeps acquisition behind sign-off with no retained request data, uses an approved no-log mirror, or disables the path before release. | Audio, transcript, callsign, route metadata, and voice samples are not uploaded by Dspeech. The caveat is request metadata that a third-party model host may receive during download. | Resolve before publishing App Privacy answers. This is a privacy-label gate, not a StoreKit/IAP gate. |
| CryptoKit SHA-256 checksum | Not a privacy-manifest required-reason API in this worksheet | `Dspeech/Core/VoiceFilter/SpeakerModelPackInstaller.swift` hashes a generated model-file manifest for local verification. | No App Store data category collected. | The checksum is derived from local model files and stays on-device as verification metadata. It is not user data and is not transmitted. | Relevant to export-compliance review, not privacy nutrition labels. |

Apple required-reason API source:
https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype

## App Store Connect privacy answers

Recommended answer for the current MVP build, after resolving the model-pack
download caveat:

1. Does the app or third-party partners collect data from this app?
   - **No, we do not collect data from this app.**
2. Tracking?
   - **No.** There is no tracking SDK, advertising SDK, data broker sharing, or
     cross-app/user profiling path in this repo.
3. Privacy Policy URL:
   - **Blocked until a public privacy-policy URL exists.** Do not enter a
     placeholder URL in App Store Connect.

## Category-by-category Not Collected justification

| App Store data category | Answer | Justification |
|---|---|---|
| Contact Info | Not Collected | No account, email form, phone-number field, or support submission exists in the app target. |
| Health & Fitness | Not Collected | Microphone audio is used for local transcription; the app does not collect health or fitness data. |
| Financial Info | Not Collected | No StoreKit/IAP code is in this slice; future Apple payment data is handled by Apple and not collected by Dspeech. |
| Location | Not Collected | No Core Location usage or flight-position upload exists. |
| Sensitive Info | Not Collected | Cockpit audio can be sensitive, but it is processed locally and not collected. |
| Contacts | Not Collected | No contacts API usage. |
| User Content | Not Collected | Audio, transcripts, voice samples, and callsigns stay on-device. |
| Browsing History | Not Collected | No web browsing surface. |
| Search History | Not Collected | No search surface. |
| Identifiers | Not Collected | No user ID, device ID, advertising ID, or vendor ID collection. |
| Purchases | Not Collected | StoreKit is out of scope for this slice. Future purchase handling must be reviewed before privacy labels are updated. |
| Usage Data | Not Collected | No analytics or telemetry code path exists. |
| Diagnostics | Not Collected | No crash or performance reporting SDK exists. |
| Other Data | Not Collected | No other app data is collected from the device. |

Apple source for privacy data types and linked/tracking definitions:
https://developer.apple.com/app-store/app-privacy-details/

## Upload blockers before App Store archive

- Bundle `PrivacyInfo.xcprivacy` with the app target in the submitted archive.
- Complete the FluidAudio `0.14.7` privacy manifest/tracking/required-reason
  audit on the processed archive.
- Resolve whether the optional model-pack download creates any third-party
  privacy-label disclosure before selecting "No data collected."
- Re-run a static privacy audit over the archive after any StoreKit, analytics,
  support, crash reporting, cloud ASR, cloud translation, or model-download
  automation is added.
- Keep final App Store privacy publication behind Andrei sign-off.
