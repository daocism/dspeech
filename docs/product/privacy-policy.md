# Dspeech — Privacy Policy

**DRAFT — not published.** Publishing this policy at a public URL is an owner
decision (Andrei). Do not enter a URL for it in App Store Connect, marketing, or
the app until that decision is made. No contact address or hosting URL in this
draft is confirmed; every bracketed placeholder must be filled in before
publication. This document describes the behavior of the current local-only
build and is written to be truthful about that build, not aspirational.

Last reviewed: 2026-07-02.

## Summary

Dspeech is a receive-only aviation transcription app for iPhone and iPad. It
turns cockpit and ATC radio audio into large, glanceable text.

- Your audio and transcripts stay on your device.
- There is no account and no sign-up.
- There is no analytics SDK, no advertising SDK, and no tracking in the app.
- The app works without a network connection for its core transcription.
- The only time the app reaches the network is when you explicitly choose to
  download an optional speech or voice-filter model. That download fetches
  public model files; it does not upload your audio, transcripts, or any
  personal data.

## Who this policy covers

This policy applies to the Dspeech iOS app. It does not cover any website,
support channel, or third-party service you might use separately.

## What the app does with your audio

When you start a session, Dspeech captures microphone or wired/Bluetooth input
audio and recognizes speech **on your device**. The default privacy mode is
`LOCAL`, shown as a badge on the main screen at all times.

- Audio is processed on-device and is **not uploaded** to Dspeech or any third
  party in local mode.
- The recognized transcript is displayed on-device and is **not uploaded** in
  local mode.
- The live audio buffer is not written to permanent storage by default.
- A transcript is saved to your device only if you keep it (session history).
  Saved transcripts remain on your device.

The current build has no cloud transcription and no cloud translation path.
Audio does not leave your device during normal use.

## Information stored on your device

Dspeech stores a small amount of state locally, in the app's private storage, to
remember your settings and content between launches. This includes:

- your privacy mode, engine choice, and app settings;
- voice-filter settings and any callsign you enter;
- the installation state of optional model packs;
- session transcripts you choose to keep.

This information is kept in the app sandbox (app settings and local files). It is
used only to restore your app state and content. It is **not transmitted** to
Dspeech, to Apple beyond normal operating-system services, or to any third-party
analytics service. (For transparency, the app's privacy manifest declares one
required-reason API — user-defaults access, reason `CA92.1` — for exactly this
local-settings purpose, and declares no data collection and no tracking.)

## Optional model downloads

Some optional features — a multilingual speech model (WhisperKit), an
English-only low-latency speech model (Parakeet), and the voice-filter speaker
model pack (FluidAudio) — require model files that are not bundled in the app.
If, and only if, you explicitly choose to install one of these, the app
downloads the corresponding model files from Hugging Face
(`huggingface.co`), the public host for those model repositories.

- The download fetches **public model files**. It transfers files **to** your
  device; it does **not** upload your audio, transcripts, voice samples,
  callsigns, or any other personal data.
- As with any file download, the model host necessarily receives the ordinary
  technical information required to serve a web request (for example your device
  IP address and standard request headers). Dspeech does not add identifiers,
  account information, or usage data to these requests.
- Downloads use pinned model revisions and per-file integrity checks. After a
  model is installed, it runs entirely on-device.

If you never install an optional model, the app makes no such network request.

## Permissions

Dspeech asks for the permissions it needs to transcribe on-device:

- **Microphone** — to capture the audio it transcribes.
- **Speech Recognition** — to convert that audio into text on your device.

You can review or revoke these at any time in the iOS Settings app. Audio and
transcription are processed locally; the microphone permission is not used to
send audio off your device.

## Data sharing and selling

Dspeech does not sell your personal information and does not share it for
advertising, cross-app tracking, or data-broker purposes. There is no
advertising, no third-party analytics, and no tracking identifier in the app.

## Data retention and deletion

Because your data stays on your device, you are in control of it:

- **Delete individual sessions** in the app's session history.
- **Delete the app** to remove all locally stored Dspeech data, including saved
  transcripts, settings, and any installed model packs.

Dspeech does not hold a copy of your data on a server, so there is nothing for us
to retain or delete on your behalf.

## Children

Dspeech is a utility aimed at pilots and student pilots and is not directed at
children. It does not knowingly collect personal information from anyone,
including children, because it does not collect personal information at all.

## Your rights (GDPR / UK GDPR, CCPA / CPRA and similar)

In the current local-only build, Dspeech (the company) does not receive or
process your personal data — it stays on your device, under your control. In
data-protection terms, when everything stays on your device you hold and manage
that data directly.

- **Access, correction, export, deletion:** your transcripts and settings are on
  your device and can be viewed, changed, exported (via the app's share/export
  options), or deleted by you at any time.
- **No sale / no sharing (CCPA/CPRA):** Dspeech does not sell or share personal
  information, so there is no opt-out to exercise.
- If a future version of the app ever introduces an optional cloud feature, it
  will require your explicit opt-in, disclose what leaves your device, and this
  policy will be updated before that feature ships.

## Changes to this policy

If this policy changes, the updated version will be dated at the top. Material
changes that affect how the app handles your data will be described in plain
language.

## Contact

For privacy questions about the app, contact: **[privacy contact to be
confirmed by the owner before publication]**.

---

This draft is consistent with the app's Architecture Decision Record on
local-only privacy (ADR 0002), the app's `PrivacyInfo.xcprivacy` manifest, the
App Store privacy nutrition-label mapping, and the internal regulatory memo. It
is not legal advice; counsel review is recommended before public launch,
especially for any future cloud feature.
