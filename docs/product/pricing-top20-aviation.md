# Pricing — top-20 developed aviation markets (excluding CIS)

Status: draft v1 (2026-05-18). Anchors based on comparable products (see ADR 0003). All prices are local-currency-list, App Store tier-aligned, before VAT/sales tax. CIS strictly excluded per Andrei.

## Market selection

Selected on three filters: (a) developed economy / high GDP-per-capita, (b) sizable commercial-airline pilot base + GA scene, (c) high iPhone share / App Store presence. 20-country cut, ordered by combined airline pilot population × ARPU potential.

1. United States — Tier A
2. United Kingdom — Tier A
3. Germany — Tier B
4. France — Tier B
5. Japan — Tier B
6. Australia — Tier A
7. Canada — Tier A
8. Italy — Tier C
9. Spain — Tier C
10. Netherlands — Tier B
11. Switzerland — Tier A
12. Sweden — Tier B
13. Norway — Tier A
14. Denmark — Tier A
15. Belgium — Tier B
16. Austria — Tier B
17. Ireland — Tier A
18. Singapore — Tier A
19. South Korea — Tier B
20. United Arab Emirates — Tier A

Explicitly excluded (CIS, per Andrei): Russia, Belarus, Ukraine, Kazakhstan, Uzbekistan, Armenia, Azerbaijan, Georgia, Kyrgyzstan, Tajikistan, Turkmenistan, Moldova.

## Tier multipliers

| Tier | Multiplier vs Tier A | Rationale |
|---|---|---|
| A | 1.00 | Highest aviation ARPU, USD/CHF/AED/SGD/AUD-strong, mature App Store spend |
| B | 0.85 | EU mid-band, JPY/KRW slightly weaker, more price-sensitive GA |
| C | 0.70 | IT/ES — large pilot pool, lower discretionary spend, Apple-tier alignment |

## Per-SKU price grid

Tier A (USD list; App Store currency-converted by Apple's tier matrix):

| SKU | Hours | Price | $/h |
|---|---|---|---|
| `trial` | 1 | free | 0 |
| `starter_10` | 10 | $39 | $3.90 |
| `standard_50` | 50 | $129 | $2.58 |
| `pro_200` | 200 | $399 | $2.00 |
| `career_unlimited_year` | unlimited / 12 mo | $999 | n/a |

Tier B (≈ ×0.85 → snap to nearest App Store tier):

| SKU | Hours | Price | $/h |
|---|---|---|---|
| `starter_10` | 10 | $32.99 | $3.30 |
| `standard_50` | 50 | $109.99 | $2.20 |
| `pro_200` | 200 | $339.99 | $1.70 |
| `career_unlimited_year` | 12 mo | $849.99 | n/a |

Tier C (≈ ×0.70):

| SKU | Hours | Price | $/h |
|---|---|---|---|
| `starter_10` | 10 | $26.99 | $2.70 |
| `standard_50` | 50 | $89.99 | $1.80 |
| `pro_200` | 200 | $279.99 | $1.40 |
| `career_unlimited_year` | 12 mo | $699.99 | n/a |

## Currency-level reference (anchor list-price, illustrative — Apple's matrix is binding at submission time)

| Country | Currency | Starter 10 | Standard 50 | Pro 200 | Career/yr |
|---|---|---|---|---|---|
| US | USD | 39 | 129 | 399 | 999 |
| GB | GBP | 32.99 | 109 | 339 | 849 |
| DE | EUR | 32.99 | 109 | 339 | 849 |
| FR | EUR | 32.99 | 109 | 339 | 849 |
| JP | JPY | 4 800 | 16 000 | 49 800 | 124 800 |
| AU | AUD | 59.99 | 199 | 619 | 1 549 |
| CA | CAD | 52.99 | 174 | 539 | 1 349 |
| IT | EUR | 26.99 | 89.99 | 279 | 699 |
| ES | EUR | 26.99 | 89.99 | 279 | 699 |
| NL | EUR | 32.99 | 109 | 339 | 849 |
| CH | CHF | 35.99 | 119 | 369 | 919 |
| SE | SEK | 359 | 1 199 | 3 699 | 9 299 |
| NO | NOK | 419 | 1 399 | 4 299 | 10 799 |
| DK | DKK | 269 | 899 | 2 779 | 6 979 |
| BE | EUR | 32.99 | 109 | 339 | 849 |
| AT | EUR | 32.99 | 109 | 339 | 849 |
| IE | EUR | 38.99 | 129 | 399 | 999 |
| SG | SGD | 52.99 | 174 | 539 | 1 349 |
| KR | KRW | 44 000 | 149 000 | 459 000 | 1 149 000 |
| AE | AED | 142.99 | 469 | 1 459 | 3 669 |

## Discount fences (no haggling at point of sale)

- **Trial → first purchase**: any pack within 7 days of trial expiry gets 1 free hour added (delivered as a non-buyable bonus, tracked locally).
- **Refer-a-pilot**: gifting a `starter_10` to another pilot gives the gifter +5 h. Cap: 2 gifts/year/Apple ID.
- **Flight-school/CFI**: dedicated `career` SKU at parent price; no further cuts. Anti-arbitrage.
- **No CIS region pricing**. App Store geo: country availability list strictly excludes CIS markets at submission.

## Open questions

- Apple's StoreKit-2 consumable receipt expiry for never-expire packs (Apple now keeps consumable receipts permanently on the server-side post-iOS 15.4; confirm at submission).
- VAT presentation: Apple handles VAT on its side; list prices on landing must say "VAT included where applicable".
- Whether to expose multi-currency on the landing for non-App-Store discovery (default: yes, USD plus local of visitor's geo via IP).
