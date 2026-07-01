# TestFlight setup worksheet

Status: staged below-upload package. Do not upload, submit, invite external
testers, or publish metadata without Andrei sign-off.

Current credential check: `op item list --vault MyInfra-Active | rg -i
'app.?store|connect|asc|apple'` returned no App Store Connect API key item in
this run. Use the manual Xcode flow until a least-privilege API key is created
and stored in 1Password.

Apple sources:

- Upload builds: https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds
- TestFlight overview: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview
- Add internal testers: https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/
- Export compliance: https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/

## Manual Xcode flow

1. Apple Developer account holder creates or confirms the app record:
   - Bundle ID: `com.dspeech.app`
   - App name draft: `Dspeech ATC`
   - Primary category draft: `Navigation`
   - Secondary category draft: `Productivity`
2. In Xcode, keep automatic signing on unless Andrei chooses manual signing.
3. Confirm target settings before archive:
   - `MARKETING_VERSION = 0.1.0` or approved release version.
   - `CURRENT_PROJECT_VERSION` increments monotonically for each uploaded build.
   - `TARGETED_DEVICE_FAMILY = 1,2` only if iPad screenshots and layout are being
     shipped.
   - `PrivacyInfo.xcprivacy` is bundled.
   - `ITSAppUsesNonExemptEncryption = NO` is present.
4. Product > Archive.
5. Organizer > Distribute App > App Store Connect.
6. Choose internal distribution only unless Andrei explicitly authorizes external
   TestFlight or App Review submission.
7. Wait for App Store Connect processing, then verify:
   - build appears under TestFlight;
   - export compliance is complete;
   - privacy answers are unpublished until approved;
   - no IAP products are expected for this slice.

## Optional automation flow after credentials exist

Only adopt this path after creating Dspeech-scoped 1Password items:

- `op://MyInfra-Active/dspeech-apple-distribution-certificate/credential`
- `op://MyInfra-Active/dspeech-apple-distribution-certificate-password/credential`
- `op://MyInfra-Active/dspeech-app-store-provisioning-profile/credential`
- `op://MyInfra-Active/dspeech-app-store-connect-api-key/credential`
- `op://MyInfra-Active/dspeech-app-store-connect-api-key-id/credential`
- `op://MyInfra-Active/dspeech-app-store-connect-issuer-id/credential`

The App Store Connect key must be least-privilege for Dspeech upload/internal
TestFlight operations only. Do not reuse a fleet-wide ASC key here.

Required constraints:

- signing certificates and provisioning profiles are consumed from Dspeech-scoped
  `op://` items only, with temporary local import on the Mac build machine;
- App Store Connect API private key is never committed, printed, or passed in
  argv;
- automation may build/archive/upload only after explicit approval, but it must
  not submit for beta review, publish privacy answers, edit production metadata,
  invite external testers, or send emails/DMs without explicit sign-off.

No automation lane is defined in this package. Add one only after the six
`op://` items exist and the release pipeline is re-audited.

## Internal testers configuration

- Create internal group: `Dspeech Internal`.
- Internal testers must be App Store Connect users with access to the app.
- Apple allows up to 100 internal testers.
- Use automatic distribution only for trusted internal builds; otherwise add
  builds manually.
- Builds uploaded as `TestFlight Internal Only` can only be assigned to internal
  groups and cannot be used for external testing or customer distribution.

## Build-number policy

- `MARKETING_VERSION`: human release version, semver-like.
- `CURRENT_PROJECT_VERSION`: monotonically increasing integer build number.
- Never reuse an uploaded build number for the same marketing version.
- Record each uploaded build in release notes with commit SHA, archive machine,
  Xcode version, and screenshot folder.

## Reviewer notes draft

Use this as the private App Review / TestFlight notes seed:

```text
Dspeech is a receive-only aviation cockpit transcription utility. It does not
transmit on aircraft radios and is not certified avionics. Original radio audio
and official ATC clearances remain authoritative.

No account is required. The default privacy mode is LOCAL; cockpit audio and
transcripts are not uploaded in local mode. The voice-filter model pack, if
enabled in this build, is acquired only after an explicit user action and should
be reviewed together with the privacy worksheet.

To test: launch the app, confirm the LOCAL badge, open Settings, confirm cloud
processing is off by default, return to the main screen, and use the simulator
microphone/speech permissions if prompted.
```

## Open gates before any upload

- Apple Developer team credentials are intentionally outside this repo.
- App Store Connect API key was not found in 1Password during this run.
- The 1024px app icon exists and is wired
  (`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`,
  `Dspeech/Assets.xcassets/AppIcon.appiconset/icon-1024.png`). Dark and tinted
  icon variants and styled marketing screenshot assets are still missing from
  this checkout.
- `PrivacyInfo.xcprivacy` must be verified in the final archive.
- `ITSAppUsesNonExemptEncryption = NO` is configured in the current working
  tree and must be verified in the processed archive.
