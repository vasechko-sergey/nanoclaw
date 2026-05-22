# Jarvis Roadmap — заход 1 (приближение к «настоящему Джарвису»)

> Долговременная копия плана. Источник-черновик: `~/.claude/plans/jolly-zooming-ocean.md`.
> Отмечать `[x]` по мере выполнения — можно откатиться к этому файлу если что-то пойдёт не так.

## Context

Сегодня Jarvis — сильный **текстовый** агент. Уже есть: scheduling/cron (`schedule_task`, host-sweep), контекст гео/health из iOS, память-CRM (`groups/jarvis/memories/`), email/calendar/web через OneCLI (устанавливаемы скиллами), self-mod, APNs-доставка. Приложение: WS+reconnect, push-токен, markdown/изображения/кнопки/баннеры, сбор контекста.

Главные дыры: **1) голос — нет STT/TTS; 2) проактивность — только cron, на iOS пуш не раскрывается в нужный диалог и нет фона; 3) интеграции — календарь/контекст устройства неглубокие; 4) память/обучение — health/контекст эфемерны.**

Решение: **iOS-first, сбалансированно** = 1 крупная ставка (голос) + 2 быстрые победы (проактивность, контекст+календарь). Память — лёгкий мазок, переиспользуя существующую wiki.

---

## Крупная ставка: голосовой контур (hands-free петля)

**Цель:** нажал «говорить» → распознал → отправил → ответ озвучен. Без клавиатуры.

### Вход — STT (on-device)
`SFSpeechRecognizer` (`ru-RU`) + `AVAudioEngine`, push-to-talk кнопка в `InputBar.swift`. Транскрипт **редактируемый** перед отправкой → существующий `message`-флоу без изменений на сервере.
- Затраты: ~1–1.5 дня. Permissions `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` в `project.yml`.
- Риск: смешанный ru/en — плохое распознавание. Митигация: редактируемый транскрипт.

### Выход — TTS, два тира (оба бесплатные)
- **Тир A (сразу):** `AVSpeechSynthesizer` с качественным встроенным голосом (Enhanced/Premium ru — Milena/Юрий). Выбор голоса в `SettingsView`, авто-озвучка по тумблеру. Протокол не меняется.
- **Тир B (fast-follow):** self-hosted TTS на VDS (Silero/Piper), без API-затрат. Аудио как `type: file` (`audio/mpeg`) — доставка файлов уже есть (`ios-app.ts:113-141`); на клиенте аудио-пузырь.
- Риск Тир B: нагрузка/латентность на VDS. Митигация: кэш фраз, замер CPU.

**Откладываем:** wake-word/непрерывное прослушивание, стриминг ответа.

**Файлы:** новые `Services/SpeechManager.swift`, `Services/SpeechSynthesizer.swift`; `Components/InputBar.swift`; `Models/AppSettings.swift`; `Views/SettingsView.swift`; `project.yml`. Тир B: `MessageBubble.swift`, `groups/jarvis/CLAUDE.md`.

---

## Быстрая победа 1: проактивность реально доходит на iOS

1. **Deep-link пуша.** `AppDelegate` (`JarvisApp.swift:4-21`) только регистрирует токен. Добавить `didReceiveRemoteNotification` + `UNUserNotificationCenterDelegate` → тап открывает нужный `conversationId`. APNs payload (`ios-app.ts:66`) расширить полем `conversationId`.
2. **Фон.** `remote-notification` background mode + опц. `BGAppRefreshTask` для свежего контекста.

Агент: задачи «утренний бриф», «напоминание за N мин до встречи»; в CLAUDE.md — тихие часы + лимит частоты.
- Риск: silent-push не гарантирован; over-notification. Митигация: alert-push, тихие часы.

**Файлы:** `JarvisApp.swift`, `Services/AppCoordinator.swift`, `project.yml`, `src/channels/ios-app.ts:66`, `groups/jarvis/CLAUDE.md`.

---

## Быстрая победа 2: глубже контекст + календарь

1. **iOS — `ContextBuilder.swift`:** батарея, связь (wifi/cellular), модель устройства, ближайшее событие календаря (`EventKit`). Сервер уже рендерит произвольный блок (`buildCtx` `ios-app.ts:446`).
2. **Агент — `/add-gcal-tool`** (скилл есть) → реальное чтение/создание событий, топливо для проактивных напоминаний.
- Риск: приватность (тумблеры — паттерн есть), OAuth на VDS. Митигация: ставить после голоса.

**Файлы:** `Utility/ContextBuilder.swift`, `Models/AppSettings.swift`, `SettingsView.swift`, `project.yml` (`NSCalendarsUsageDescription`); агент — `/add-gcal-tool`.

---

## Память/обучение — лёгкий мазок — переиспользуем существующее

Память — wiki (`groups/jarvis/memories/`): `index.md`, `self/`, `people/`, `interactions/<YYYY-MM>/`, append-only `log.md`. **Ничего нового не строим.**

CLAUDE.md §5: health эфемерны, в профиль не писать. Raw оставляем эфемерными. Точечно: разрешить **агрегаты** на `self/health.md` (как `self/surfing.md`) — еженедельный дайджест трендов, регистрация в `index.md`; значимые сдвиги — в `log.md`. Правка §5/§6 CLAUDE.md + scheduled-task. Реальное обучение на паттернах — отдельный заход.

---

## Порядок исполнения (чек-лист)

- [x] **1. STT (вход)** — `SpeechManager`, кнопка-микрофон, редактируемый транскрипт. Код собран (BUILD SUCCEEDED); финальная проверка микрофона — на девайсе.
- [x] **2. TTS Тир A** — `SpeechSynthesizer`, выбор Enhanced ru-голоса, авто-озвучка. Собрано (BUILD SUCCEEDED). Полный hands-free цикл.
- [x] **3. Проактивность** — deep-link пуша (UNUserNotificationCenterDelegate) + background mode + `conversationId` в payload + тихие часы/лимит в CLAUDE.md. Собрано. Финальная проверка — на девайсе с APNs.
- [x] **4. Контекст** — `ContextBuilder` + `CalendarManager` (EventKit) + `ConnectivityMonitor`: батарея/энергосбережение/сеть/ближайшее событие, тумблер «Календарь». Собрано (iOS+TS).
- [ ] **5. gcal-скилл** + проактивные задачи (бриф/встречи).
- [ ] **6. TTS Тир B** — self-hosted Silero/Piper на VDS, аудио-пузырь.
- [x] **8. Озвучка voice-in→voice-out + ручная** — флаг `lastSendWasVoice`, gating авто-озвучки, меню-пункт «Проговорить», лейбл тумблера «Озвучивать ответы на голос». Собрано.
- [x] **9. Читаемые статусы** — `StatusBanner` → карточка на всю ширину с переносом текста (убраны сжимающие линии + lineLimit). Собрано.
- [x] **7. Память** — `self/health.md` scaffold + регистрация в `index.md`, правка §5/§6 CLAUDE.md (raw эфемерны, недельный агрегат разрешён). Recurring `schedule_task` агент заведёт сам.

Голос (1–2) — крупная ставка. 3–4 параллельно. 5–7 — далее.

## Заход 2 — автономный health-агент «Грег» (построено, развёрнуто)

- [x] **10. iOS fetch_health** — `HealthHistory.swift` daily-бакеты на устройстве; WS `fetch_health`/`health_history`. Собрано.
- [x] **11. Host store+watcher** — `ios-app.ts`: `health_history`→`raw.jsonl`, watcher обслуживает `requests/`. Развёрнуто. **Mounts не нужны** — данные в папке группы Грега (авто-mount, как у Джарвиса).
- [x] **12. Грег + analyzer** — `groups/health-analyzer/{CLAUDE.md, scripts/analyze.js (Bun — python нет в образе), memories/state.md}`. analyze.js протестирован в реальном образе (RHR→critical). agent_group `7f502486-b4e7-47f8-9a3a-4f21ebdba88e`.
- [x] **13. a2a + гейт** — destinations jarvis↔health-analyzer связаны. Джарвис §9: findings по a2a → фильтр тихие часы/лимит → critical Сергею; recheck loop-guard; 👎→suppress. Handoff через a2a (findings редки), не shared-folder.
- [x] **14. Активация — РАБОТАЕТ end-to-end.** Джарвис пингнул Грега → Грег завёл recurring `schedule_task` (ежедневно 09:00 UTC) + записал `init_14d.json` → host watcher → `fetch_health` → app (онлайн) → `health_history` +15 дней → `raw.jsonl` (15 строк реальных данных) → Грег отчитался Джарвису. Все 5 звеньев живые.

**Идентификаторы:** Jarvis `ag-1778740750341-ru9i6e`, Greg **`greg`** (пересоздан: OneCLI требует identifier с буквы, UUID с цифры отвергался — баг `ncl groups create`, чип на починку). Данные Грега: `groups/health-analyzer/health/{raw.jsonl, requests/}`.

## Заход 3 — фоновый health-sync (без открытого app)

- [x] **15. Сервер** — `sendApnsSilentPush` (content-available), watcher-фоллбэк на push при отсутствии WS, `POST /ios/health/upload` (Bearer-auth) + общий `ingestHealthHistory`. Задеплоено; эндпоинт проверен (401 без auth, 200 с auth).
- [x] **16. iOS Background Delivery (A)** — `HealthSync.swift`: `enableBackgroundDelivery` + `HKObserverQuery` по 7 типам → `HealthUpload` при новых данных. Собрано.
- [x] **17. iOS silent-push fetch (B)** — `HealthUpload.swift`; `AppDelegate` content-available → `HealthHistory.fetch` → upload; `project.yml` background modes + healthkit background-delivery entitlement. Собрано.

**Проверка на девайсе (Сергей):** поставить новый build → свернуть app (не убивать) → положить запрос в `requests/` на VDS → silent push разбудит → `raw.jsonl` обновится без открытия app. Background delivery — при новых health-данных. **Force-quit глушит оба** (iOS-правило).

**Грабли активации (на будущее):** (1) `ncl groups create` не создаёт `container_configs` → `ensureContainerConfig` вручную. (2) OneCLI identifier должен начинаться с буквы. (3) После пере-вайринга destinations нужно перепроецировать в `inbound.db` живого агента (`writeDestinations`) — `docker restart` не перепроецирует. (4) headless-агент будится только сообщением от другого агента.

---

## Verification

**iOS (локально):**
```bash
cd ios/JarvisApp && xcodegen generate
```
Сборка через XcodeBuildMCP (`build_run_sim`) или на девайсе (мик/HealthKit/календарь).

**Сервер (после правок ios-app.ts / CLAUDE.md):**
```bash
pnpm run build && git push
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && git pull && pnpm run build && bash ~/nanoclaw/start-nanoclaw.sh"'
```
Health: `GET http://100.94.184.60:3001/ios/health` → `{"ok":true}`.

**Открытый вопрос (перед Тиром B):** Silero (лучший русский, pip+torch) vs Piper (легче, ONNX) — после замера CPU/RAM VDS.
