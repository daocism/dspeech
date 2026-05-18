# Regulatory & privacy memo

Date: 2026-05-18. Status: draft, internal use; NOT legal advice — Andrei to engage counsel before App Store submission in regulated markets.

## Scope

Receive-only iPhone app that captures cockpit/ATC audio, transcribes it on-device by default, optionally translates, and (with explicit opt-in) sends segments to cloud APIs. Sold to general-aviation pilots and student pilots in the top-20 developed aviation markets (per `pricing-top20-aviation.md`); no CIS.

## Receive-only positioning (aviation regulators)

| Region | Authority | Posture |
|---|---|---|
| US | FCC (Part 87 radio licensing) + FAA (Part 91 ops) | Dspeech does NOT transmit on aeronautical bands. Listening to ATC on monitor headphones / through wired audio is not a Part 87 transmission. App Store copy must explicitly say "receive-only, does not transmit." |
| EU | EASA + national CAAs | Same posture; no transmission, no AOC impact. |
| UK | CAA + Ofcom | Same. |
| AU | CASA + ACMA | Same. |
| CA | Transport Canada + ISED | Same. |
| JP | JCAB | Same. |

The product MUST NOT make claims of decision-making authority. Acceptance criterion in App Store copy: presence of the disclaimer "Aid only. Pilot remains responsible for all communications and decisions."

## Privacy regulators (data protection)

Audio = personal data when third-party voices may be captured (ATC controllers, other pilots). On-device default minimizes scope; cloud opt-in materially expands it.

### GDPR / UK GDPR (EU + UK)

- **Lawful basis**: under `.localOnly` no personal data is processed by Dspeech-the-company (data never leaves the user's device). The user IS the controller of their own device.
- Under `.allowCloudFallback`: Dspeech becomes a processor for the user's audio. Need:
  - Privacy Policy in plain English (+ RU, target-language). Sections required: data categories, purpose, retention, sub-processors (cloud ASR/MT providers), data residency, user rights (access/erase/portability), DPO/contact, complaint route.
  - DPA with each cloud sub-processor (Deepgram, DeepL, etc. per `cloud-fallback-matrix.md`).
  - Records of processing (Art. 30) once active in EU.
  - SCCs or equivalent for any US-bound transfer.
- **Third-party voices (ATC controllers)**: capturing their voices for personal use is generally permissible (household exemption ambiguous; legitimate-interest argument credible for pilots' own training). Distributing/publishing those recordings is NOT in scope and is not enabled by the app.
- **Children**: GA pilot training has minors (student pilots can be ≥ 14 in glider, ≥ 16 in powered). Add age-gate copy and parental-consent path for cloud opt-in if we ship to under-16.

### CCPA / CPRA (California)

- "Do Not Sell or Share My Personal Information" link required if we run any ads or share with third parties. MVP doesn't, so this is satisfied passively.
- If we ever add analytics, gate behind explicit opt-in and provide a clear opt-out.

### PIPL (China)

- Out of scope at MVP launch. China requires data localization, cybersecurity review for cross-border transfer, and ICP filing for app distribution. Defer.

### Brazil LGPD, Japan APPI, Australia Privacy Act 1988

- Similar shape to GDPR-lite. Compliant by default if GDPR posture is met. Explicit Privacy Policy translation required in PT-BR and JP for the App Store.

## Aviation-specific privacy

- ATC frequencies are public broadcasts in most jurisdictions. Recording for personal use generally permissible.
- Some EU jurisdictions (DE, FR) treat continuous recording of communications as potentially regulated under interception laws. Mitigation: receive-only, on-device, no auto-retention. Audio buffer never persisted by default; transcript persistence is user-toggled.
- Pilots subject to airline / school SOPs that may prohibit recording during ops. Out of our control — surface in onboarding "check with your airline/school".

## App Store policy

- App Store Review Guidelines 5.1.1, 5.1.2 (data collection + consent): need Privacy Policy URL, App Privacy "nutrition label", and accurate description of cloud use.
- Privacy label (MVP `.localOnly`): "Data Not Collected" track. When cloud is enabled by the user, in-app disclosure required, but App Privacy nutrition label can reflect "user-toggled".
- Subscription / IAP: hour-pack model is consumable IAP per ADR 0003; needs Apple's standard consumable disclosures.

## Required artifacts before public launch

1. Privacy Policy page on landing site (EN + RU minimum, expand to target-language list).
2. Terms of Service page including receive-only / pilot-responsibility clause.
3. App Privacy questionnaire answers (App Store Connect).
4. DPA with each enabled cloud provider.
5. Standard Contractual Clauses where transfers are EU → non-EU.
6. Records of processing (Art. 30) — kept internal once we have any EU users in cloud mode.
7. Contact email for data-subject requests (proposed: `privacy@dspeech.app` — Andrei to confirm domain ownership).

## Open questions (Andrei action required)

- Engage a privacy lawyer (EU + US) for review before public App Store launch. Receive-only posture is straightforward; cloud opt-in is the area where legal sign-off is non-optional.
- Decide whether to incorporate an entity for data-controller role (EU often expects a named legal entity). 
- Confirm domain `dspeech.app` ownership / register if not.

## References

- ADR 0001, ADR 0002, `prd-ios-mvp.md`, `cloud-fallback-matrix.md`, `language-pack-spec.md`, `pricing-top20-aviation.md`.
