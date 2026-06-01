# App Store age rating worksheet

Status: staged answers for App Store Connect. Do not submit without Andrei
sign-off.

Apple requires an age rating and generates it from the App Store Connect
questionnaire. Sources:

- https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating
- https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/

## Recommended rating outcome

Target outcome: **4+**

Do not mark as Made for Kids. Dspeech is a professional aviation utility, not a
children's app.

## Questionnaire answers

| Category | Answer | Justification |
|---|---|---|
| Parental controls | No | No child-management or parental-control feature exists. |
| Age assurance | No | No age check or age verification feature exists. |
| Unrestricted web access | No | The app has no embedded browser or general web navigation. |
| User-generated content | No | Audio/transcripts stay local and are not broadly distributed. |
| Messaging and chat | No | The app has no user-to-user messaging. |
| Advertising | No | No ads or ad SDKs are present. |
| Contests | No | No contests or chance-based activities. |
| Loot boxes | No | No game mechanics. |
| Gambling or simulated gambling | No | No gambling mechanics. |
| Profanity or crude humor | None | The app does not provide entertainment content or generated profanity. |
| Horror or fear themes | None | Not present. |
| Mature or suggestive themes | None | Not present. |
| Sexual content or nudity | None | Not present. |
| Alcohol, tobacco, or drug use references | None | Not present. |
| Medical or treatment information | None | Dspeech is an aviation utility, not a medical/wellness product. |
| Cartoon or fantasy violence | None | Not present. |
| Realistic violence | None | Not present. |
| Guns or other weapons | None | Not present. |

## Reviewer-facing note

Dspeech is a receive-only aviation transcription utility. It does not transmit
on aircraft radios, does not provide flight instructions, and is not certified
avionics. The original ATC audio and official clearances remain authoritative.

## Re-check triggers

Re-run this worksheet if the app adds:

- open web content;
- user messaging or public transcript sharing;
- ads;
- AI chat visible to end users;
- training content with emergency scenarios, weapons, injury, or mature themes;
- medical/wellness claims.
