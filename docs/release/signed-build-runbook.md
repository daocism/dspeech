# Signed Build Runbook

This repo currently supports unsigned archives and local/CI validation. Signed distribution remains blocked until Apple signing assets, App Store Connect API credentials, export compliance answers, App Privacy answers, and TestFlight metadata are present and approved.

No CI submission automation is enabled. Use Xcode Organizer or Transporter for the first signed TestFlight path.

## Secret References

Create these 1Password items before enabling any signed upload path:

- `op://MyInfra-Active/dspeech-apple-distribution-certificate/credential`
- `op://MyInfra-Active/dspeech-apple-distribution-certificate-password/credential`
- `op://MyInfra-Active/dspeech-app-store-provisioning-profile/credential`
- `op://MyInfra-Active/dspeech-app-store-connect-api-key/credential`
- `op://MyInfra-Active/dspeech-app-store-connect-api-key-id/credential`
- `op://MyInfra-Active/dspeech-app-store-connect-issuer-id/credential`

OP search found no Apple, App Store, or ASC items in `MyInfra-Active`, `MyInfra-Archive`, or `MyInfra-Identity` for this slice. These titles are placeholders for the items that must be created before upload is enabled.

## Certificate And Profile Intake

1. Receive the Apple Distribution certificate, private-key password if any, and App Store provisioning profile through 1Password only.
2. Import the certificate into a temporary keychain on the Mac build machine. Do not commit or print the certificate, private key, profile, exported signing identity, or password.
3. Install the provisioning profile under `~/Library/MobileDevice/Provisioning Profiles/`.
4. Confirm the profile matches `com.dspeech.app`, the Apple Team, and the current app target entitlements.
5. Build from a clean checkout:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Dspeech.xcodeproj \
  -scheme Dspeech \
  -configuration Release \
  -destination generic/platform=iOS \
  archive \
  -archivePath tmp/release/Dspeech-signed.xcarchive
```

## Upload Path

Prefer Xcode Organizer for the first upload:

1. Open `tmp/release/Dspeech-signed.xcarchive` in Xcode Organizer.
2. Validate the archive.
3. Distribute App > App Store Connect > Upload.
4. Confirm export compliance answers in App Store Connect before release decisions.
5. Wait for the ASC build received TestFlight processing state before adding internal testers.

Transporter is acceptable after the same local signed archive validation. Keep credentials in an env file made only from `op://` references:

```bash
op run --env-file ./tmp/release/asc-upload.env -- xcrun altool \
  --upload-app \
  --type ios \
  --file ./tmp/release/Dspeech.ipa \
  --apiKey "$ASC_API_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"
```

`./tmp/release/asc-upload.env` must remain untracked and must contain only injected values or `op://` references. No `.p8`, JWT, Transporter credential, signing certificate, provisioning profile, or exported signing artifact may be committed or printed.

## Release Gate

- Local mac24 or GitHub Xcode build/test is green.
- `scripts/release/check-release-ready.sh` is green.
- Privacy manifest is bundled and validated.
- App Store privacy answers are reviewed in App Store Connect.
- Export compliance answer is set after reviewing the actual cryptography surface.
- Screenshots and localized listing copy are present.
- Signed archive validates in Xcode Organizer.
- Upload is manual through Xcode Organizer or Transporter.
- Availability matches the canonical allowlist in
  `docs/product/pricing-top20-aviation.md`.
- No outbound webhook/DM/email integration is added for release notifications.
