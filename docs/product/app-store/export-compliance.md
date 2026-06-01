# Export compliance worksheet

Status: staged answer. Do not submit or write App Store Connect metadata without
Andrei sign-off.

## Recommended App Store Connect answer

`ITSAppUsesNonExemptEncryption`: **NO**

Rationale: the current Dspeech app target does not implement proprietary,
non-standard, or app-level encryption. Speech/audio processing is not encryption.
The current cryptography-relevant surfaces are:

- HTTPS/TLS used by the operating system if a user explicitly downloads a local
  voice-filter model pack;
- `CryptoKit.SHA256` used to derive a local checksum/fingerprint over model-file
  metadata;
- Apple platform services and framework behavior.

Apple's export-compliance help states that apps using only encryption limited to
Apple's operating system require no App Store Connect export documentation.
Source:
https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption

Apple's `ITSAppUsesNonExemptEncryption` reference says setting the key to `NO`
indicates the app either uses no encryption or only exempt encryption. Source:
https://developer.apple.com/documentation/BundleResources/Information-Property-List/ITSAppUsesNonExemptEncryption

## Exemption name

Use of encryption is limited to Apple operating-system crypto / standard
transport security. No separate French encryption declaration, CCATS, or
`ITSEncryptionExportComplianceCode` is expected for the current app target.

## Repo evidence

- `Dspeech/Core/VoiceFilter/SpeakerModelPackInstaller.swift` imports `CryptoKit`
  for a SHA-256 checksum over a local generated manifest.
- `Dspeech/Core/VoiceFilter/SpeakerModelPackInstaller.swift` uses FluidAudio's
  explicit model download path only after a user action.
- No custom encryption, VPN, secure messaging, encrypted database, encrypted
  document exchange, or cryptographic protocol implementation is present in
  `Dspeech/`.
- The current working tree configures
  `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` for Debug and Release in
  `Dspeech.xcodeproj/project.pbxproj`.

## Required verification before archive

The generated Info.plist in the processed archive must contain:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

Equivalent Xcode build setting form:

```text
INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO
```

The remaining action is verification, not a new implementation requirement:
inspect the processed archive or uploaded build metadata and confirm App Store
Connect reads the answer as non-exempt encryption not used.

## Re-check triggers

Re-open this worksheet before upload if any of these land:

- cloud ASR, cloud translation, or account sync;
- custom encrypted storage;
- non-Apple cryptographic library;
- server-side receipt validation or authenticated API traffic;
- analytics, crash reporting, or support-upload SDK;
- StoreKit receipt handling beyond Apple's local signed transaction APIs.
