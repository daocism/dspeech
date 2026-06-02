# Dspeech — on-device test checklist (all functions)

Run after installing on the iPhone (see `DEVICE-INSTALL-WORKFLOW.md`). Built-in mic is
enough to exercise everything except the wired-cockpit accuracy path.

| # | Function | How to test | Expected |
|---|---|---|---|
| 1 | Install / icon | Install + look at home screen | Cyan radio-waves app icon; app launches |
| 2 | First-run onboarding (§3) | Fresh install → launch | 3 cards (Только приём / Локально / Подключите вход) → «Начать» → cockpit. Shown once |
| 3 | Live ASR (F1) | Tap «Старт», allow Mic + Speech, speak English ATC phrases | Live italic partial, then finalized **monospaced** segments with confidence % |
| 4 | Big readable transcript (F2) | Look at segments; bump iOS text size (Dynamic Type) | Monospaced, large, scales with Accessibility text size, dark |
| 5 | Tap-to-expand | Tap a segment | Expands a detail row: timestamp + confidence |
| 6 | Translation (F3) | Tap «Перевод» toggle on | First time: iOS offers to **download the language pack**; after install, a target-language gloss appears under each new segment |
| 7 | Translation target | Settings → Перевод → Целевой язык | Pick language; new glosses use it. Declined pack → «нужен языковой пакет» hint |
| 8 | Voice-filter model download | Settings → Голосовой фильтр ATC → «Скачать пакет (≈15 МБ)» | Progress → «Модель установлена и проверена» (real FluidAudio download + checksum) |
| 9 | Pilot voice enrollment | Settings → after pack installed → «Записать голос» (Pilot 1/2) | Records a voiceprint; «Голос сохранён» |
| 10 | Audio source picker (F5) | Settings → Источник звука → pick input | Selection persists across launches |
| 11 | Input level meter (F5) | Settings → Источник звука → «Проверить уровень входа», speak | Bar moves with loudness; «Остановить проверку» stops it |
| 12 | Privacy badge (F4) | Anywhere on the main screen | «LOCAL» badge always visible; route chip shows MIC / EXT |
| 13 | Recognition locale | Settings → Язык распознавания | Switch locale; ASR follows |
| 14 | Background stop (F8) | While recording, swipe to background | ASR stops cleanly (no covert capture); foreground → tap Старт to resume |
| 15 | Crash-free 60 min (F6) | Record continuously ~60 min on one charge | No crash |
| 16 | Battery (F7) | Note battery before/after a 60-min session | ≤ ~25% drain (target) |

Local-only invariant: everything above runs on-device; the only network is Apple's own
language-pack / FluidAudio model fetch. No audio, transcript, or translation leaves the phone.
