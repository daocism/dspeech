# App Store listing draft - English

Status: staged copy. Do not submit or publish without Andrei sign-off.

## Metadata fields

| Field | Draft |
|---|---|
| Name, 30 chars max | Dspeech ATC |
| Subtitle, 30 chars max | Private ATC transcript |
| Promotional text, 100 chars max | ATC transcription that stays on your iPhone. Large cockpit text, offline-first, no account. |
| Support URL | BLOCKED - public support URL required before App Store metadata submission |
| Marketing URL | BLOCKED - optional public marketing URL not approved yet |
| Keywords, 100 bytes max | atc,pilot,cockpit,aviation,transcript,radio,flight,intercom,offline,airband,student |

## Description, 4000 chars max

Dspeech turns live cockpit and ATC audio into large, glanceable text on your iPhone, with privacy as the default.

Your audio stays on your device. Dspeech is designed for local speech recognition, local settings, and no account. There is no analytics SDK, no advertising SDK, and no tracking path in the current app target.

Why pilots use it:

- Read ATC speech as big cockpit-friendly text.
- Keep the original radio audio as the authority while using text as a supplemental aid.
- See the LOCAL privacy badge on the main screen.
- See route indicators for built-in and detected input paths without sending cockpit audio to a server.
- Keep pilot voice-filter settings and model-pack state on-device.

Privacy by design:

- No account required.
- No audio upload in local mode.
- No transcript upload in local mode.
- No location tracking.
- No advertising tracking.
- No outbound support or sales messages from the app.

Important aviation notice:

Dspeech is a supplemental cockpit aid. It is not certified avionics, not an ATC authority, and not a replacement for radio monitoring, pilot judgment, ATC instructions, aircraft procedures, or required equipment. The original audio and official clearances remain authoritative.

Hardware notice:

Dspeech does not promise compatibility with every headset, intercom, aircraft, Bluetooth route, or wired adapter. Use the app's route status indicators and validate your setup before relying on any workflow.

Billing notice:

Dspeech's product plan uses usage-based hour packs instead of a flat subscription. StoreKit purchasing is not part of this readiness slice and must be configured only after the billing implementation is approved.

## Release manager notes

- Primary category draft: Navigation.
- Secondary category draft: Productivity.
- Distribution must follow `docs/product/pricing-top20-aviation.md` only.
- Do not claim translation, certified cockpit reliability, or validated hardware support until the corresponding implementation and evidence are green.
- Do not submit App Store privacy answers from automation; publish them manually in App Store Connect after Andrei approval.
