# Competitor teardown

Date: 2026-05-18. Status: draft. Public-information desk research; no in-app testing performed in this dispatch. Numbers are list anchors as of 2026-05-18 — re-verify before any external claim.

## Methodology

- App Store + product website + Reddit/forum mentions, captured 2026-05-18.
- Not yet validated: actual ASR accuracy on aviation audio. To be added once `asr-benchmark-plan.md` lets us A/B against the corpus.
- Pricing is what the vendor advertises publicly; subject to change.

## Competitor map

| Product | Platform | ASR locality | Translation | Aviation domain tuning | Pricing model | Notable |
|---|---|---|---|---|---|---|
| ATC Transcriber (LiveATC adjacent) | Web only | Server-side (cloud) | None | None | Free / community | Hobbyist quality; no live in-cockpit use |
| FlyKey ATC | iOS | Server-side | None | Aviation-tuned LLM post-processing | Subscription | Live-listening focused; cloud-dependent |
| SayIntentions.AI | iOS / desktop add-on | Cloud + in-sim | Yes (sim-side) | Sim-only, not real ATC | Sim-bundled | Different segment (sim role-play) |
| Verbex Wingman (hypothetical / similar entrants) | iOS | Cloud | Yes | Mixed | Subscription | Watch for new entrants in 2026 |
| Apple Translate + system dictation (DIY) | iOS-native | On-device (since iOS 17.4 for some langs) | Yes | None | Free | Most likely "good enough for free" alternative |
| Google Pixel Live Translate | Android | On-device | Yes | None | Bundled | Cross-platform anchor; not on iPhone |
| Otter.ai mobile | iOS / Android | Cloud | Limited | None | Freemium + sub | Meeting-tuned; aviation accuracy poor |
| Krisp Voice / RTX Voice | Desktop add-ons | On-device noise suppression | n/a | n/a | Free / pro | Adjacent — noise suppression, not ASR |

Note: this list is best-effort and INCOMPLETE. The competitive space has high churn; refresh quarterly.

## Where Dspeech wins (positioning)

1. **Local by default** — no other player in this list ships local-only-by-default + aviation-domain glossary + privacy-visible badge. (ADR 0002.)
2. **Receive-only & pilot-respect copy** — most apps imply "AI in the cockpit assists you." We position as "aid only; pilot remains responsible." (regulatory posture above.)
3. **Aviation-glossary terminology guard** — runtime guard against critical-phrase errors is unique vs general dictation/translate apps.
4. **Hour-pack pricing** — pilots fly in hours; the unit matches the use case. (ADR 0003.)
5. **Top-20 developed-market focus** — pricing tuned per region per `pricing-top20-aviation.md` rather than one-size US sub.

## Where Dspeech is at risk

1. Apple's first-party Speech + Translation are "free, decent, and pre-installed" — must beat them on aviation-domain quality, not on general ASR.
2. Cloud-ASR competitors will always win raw WER on clean audio. Our defense is privacy + on-device latency + aviation glossary.
3. Bigger entrants (Boldmethod, ForeFlight) could ship the feature inside their existing pilot app. Defense: speed of iteration + focus.

## Things to measure once we can

| Hypothesis | Test | When |
|---|---|---|
| Local Whisper-small.en beats Apple Speech on aviation WER | Benchmark per `asr-benchmark-plan.md` | After corpus v1 lands |
| Apple Translation framework is good enough for EN→RU aviation | MT benchmark | After corpus v1 lands |
| Pilots prefer hour-pack over subscription | Landing page A/B (later, with Andrei sign-off) | Post-MVP |
| Terminology-guard badges reduce mis-action rate | Lab study (deferred) | Post-MVP |

## Open questions (Andrei action required)

- Confirm priority competitors to monitor (Andrei knows the GA pilot subculture better).
- Whether to publish a public comparison table on the landing page (carries reputational risk if a competitor disputes numbers).

## References

- `prd-ios-mvp.md`, ADR 0001, ADR 0002, ADR 0003, ADR 0006, `pricing-top20-aviation.md`, `launch-positioning.md`.
