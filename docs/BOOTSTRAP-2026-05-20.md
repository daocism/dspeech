# Dspeech MVP autopilot — one-command bootstrap

## Почему не из SSH
`claude -p` через SSH видит «Not logged in» — Keychain на macOS привязан к GUI-сессии, OAuth-токен Max-подписки недоступен из SSH. Это поведение macOS, не баг. Codex CLI на mac24 не установлен (нет node/brew). Поэтому pilot стартуется **локально из Terminal.app на mac24**.

## Одна команда (открой Terminal.app на mac24, вставь, нажми Enter)

```
cd ~/projects/dspeech-ios && \
git pull --rebase origin feat/mvp-completion-2026-05-19 && \
nohup bash .agent-prompts/workday-pilot-v2.sh > .agent-logs/pilot-$(date +%Y%m%d-%H%M%S).log 2>&1 & disown && \
echo "pilot started, PID $!"
```

После этого окно Terminal.app можно закрыть — `nohup`+`disown` оставит процесс жить.

## Что произойдёт автономно (без твоего участия)

**Phase 1 (sequential)** — критический путь:
- W4b-round4 closes BLOCK-2 (9 XCUI red specs → green)
- W7 verifier гоняет 8 гейтов
- W8 Gemini design-review на скриншотах
- W9 docs + Notion-tasks template + CHANGELOG

**Phase 2 (4-parallel)** — hardening:
- W10 threading audit (Swift 6 strict concurrency)
- W11 error taxonomy (typed errors, single boundary)
- W12 cold-start budget
- W13 privacy manifest (PrivacyInfo.xcprivacy)

**Phase 3 (4-parallel)** — reviewer pass на каждую hardening-ветку.

**Phase 4 (sequential)** — UI polish:
- W14 Liquid Glass / iOS 26 материалы (premium look, не cargo-cult)
- W15 accessibility (VoiceOver, Dynamic Type, contrast)
- W16 Gemini iteration на новые скриншоты

**Phase 5 (sequential)** — финал:
- W17 merge всего в `feat/mvp-completion-2026-05-19`, единый PR, push, обновление `docs/MISSION_REPORT-2026-05-20.md` + `docs/DEVICE-VERIFICATION-iPhone17ProMax.md` + Notion tasks файл.

## Триггер «всё готово»

На mac24 появится один из двух файлов:
- `docs/MISSION_REPORT-2026-05-20.md` — успех, ветка запушена, ты можешь брать sideloaded build и идти проверять на iPhone 17 Pro Max по `docs/DEVICE-VERIFICATION-iPhone17ProMax.md`
- `docs/NEEDS-HUMAN.md` — pilot уперся 5× подряд без прогресса. Там точное место и что от тебя нужно (обычно: подпись провижининга, scope-решение, или подтверждение архитектурного компромисса).

Notion-задачи pilot будет писать в `docs/NOTION-TASKS-2026-05-20.md`. Я их потом сам перенесу в твою Notion-страницу `APP-Dspeech` когда вернёшься, либо могу настроить Notion MCP push если дашь токен.

## Мониторинг (опционально, если захочешь зайти посреди дня)

```
ssh mac24 'tail -f ~/projects/dspeech-ios/docs/AUTOPILOT-JOURNAL.md'
ssh mac24 'cat ~/projects/dspeech-ios/docs/NEEDS-HUMAN.md 2>/dev/null || echo OK pilot still working'
ssh mac24 'cd ~/projects/dspeech-ios && git log --oneline origin/feat/mvp-completion-2026-05-19..HEAD'
```

## Защита от тайм-аута WebUI (мой контракт с собой)

Любая команда из WebUI-сессии теперь либо <2 мин, либо `nohup`+`disown` + чтение `tail -n 200` отдельным коротким вызовом. Никаких foreground `xcodebuild`, никаких foreground `git push` от агентов через SSH. Это устраняет «timeout: streaming exceeded 600s» в корне.
