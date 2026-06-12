# Shared agent profiles + body-comp + health-pull fix (design)

**Дата:** 2026-06-11
**Статус:** дизайн утверждён (модель A, discovery-first, scrooge округляет), готов к плану
**Контекст:** реализует оставшуюся работу Гордона («Фаза 4») + системную возможность, которую она мотивировала. Заменяет a2a-only план Фазы 4 из [gordon-nutrition-agent-design](2026-06-11-gordon-nutrition-agent-design.md).

## Зачем

Гордон (Фазы 1-3, задеплоено) логирует еду, считает рекомп-таргеты, даёт дневной итог. Чтобы судить рекомп, ему нужен **тренд состава тела** (вес/жир/сухая) — он у Грега. Чтобы Грег объяснял плохое восстановление — ему нужен **интейк** Гордона. Чтобы Jarvis собирал бриф — ему нужны сводки всех.

Наивное решение — попарные a2a-контракты (Greg↔Gordon, Gordon↔Payne, *→Jarvis). Это **N² контрактов** и не масштабируется. Лучше: **каждый агент публикует короткую публичную сводку своего домена; любой агент читает чужую при необходимости.** Pull вместо push для ambient-контекста; a2a остаётся только для срочного.

Плюс найден **блокер**: `request_context` (как агент тянет live-данные с iOS) зарегистрирован только для legacy-канала `ios-app`, а v2-агенты на `ios-app-v2` → **pull-контекст мёртв у Грега и Гордона**. Чинится отдельно, нужно для забора веса/роста.

## Не-цели (YAGNI)

- Не realtime-синхронизация фрагментов. Обновление на дневном цикле агента + хост-проекция раз в свип — достаточно.
- Не сложная ACL. Каждый пишет свой фрагмент, читает чужие RO. Конвенция + хост-проекция, не криптография.
- Не гнать body/health в контекст КАЖДОГО сообщения. Только pull (`request_context`) on-demand + дневной upload.
- Не полный body-comp UI. iOS просто отдаёт поля; интерпретация — у Грега/Гордона.
- Scrooge не выставляет точные суммы — только огрублённые полосы (см. §B).

---

## A. Разблокировать health-pull (фикс + legacy-чистка)

**Проблема:** `container/agent-runner/src/mcp-tools/request_context.ts:236` — `if (opts.channel_type !== 'ios-app') return;`. `channel_type` сессии (из `getSessionRouting()`, см. `mcp-tools/index.ts:25`) = `ios-app-v2`. Гейт сверяется со СТАРЫМ v1-именем → тул не регистрируется → агент его не видит. iOS+host плумбинг существует (`AppContextCoordinator.health()`, `context-bridge.ts`), но мёртв сверху.

**Фикс:** гейт → `if (!opts.channel_type?.startsWith('ios-app')) return;` (ловит и `ios-app`, и `ios-app-v2`, future-proof). Оживляет pull у ВСЕХ iOS-агентов (Грег тоже получает рабочий `request_context(["health"])`).

**Legacy-чистка:** v1-адаптер уже удалён. Остаточные ссылки на старый `channel_type 'ios-app'` (не `ios-app-v2`, не платформенный префикс `ios-app:`) — проверить grep'ом и поправить ветки, которые сверяются со старым именем. Малый diff.

**Деплой:** правка в `container/agent-runner/` → **пересборка образа** (`./container/build.sh`) + редеплой на VDS. Не scp.

---

## B. Система публичных профилей (бэкбон)

### Раскладка

`groups/global/profiles/<agent-slug>.md` — короткая публичная сводка домена каждого агента. Плюс существующий `groups/global/about-sergei.md` (канонические факты о Сергее) остаётся.

Содержимое (каждый держит актуальным):
- `greg.md` — готовность, восстановление, **тренд тела (вес/жир/сухая)**, активные health-флаги.
- `gordon.md` — текущие рекомп-таргеты, адерентность (белок-стрик, средние ккал vs цель), цель.
- `payne.md` — активная программа, последняя/следующая тренировка, недельный объём, трен-день да/нет.
- `scrooge.md` — финансы **огрублённо** (полоса runway типа «6-9 мес», тренд burn «растёт/ровно», НЕ точные суммы/балансы).
- `jarvis.md` — опц.: текущий фокус/локация/ближайшие события (Jarvis больше читатель-оркестратор, фрагмент по желанию).

### Модель записи (A — утверждено)

Агент пишет сводку в **свой воркспейс**: `/workspace/agent/memories/public.md` (= `groups/<folder>/memories/public.md` на хосте). **Хост проецирует** её в `groups/global/profiles/<slug>.md`. Паттерн «пиши своё, хост раздаёт» — как сессионные БД. Без кросс-маунт-записи, без затирания чужого.

- **Проекция:** хост-свип (`src/host-sweep.ts`, 60с) копирует каждый `groups/<folder>/memories/public.md` → `groups/global/profiles/<slug>.md` при изменении (mtime/hash). Дёшево, near-real-time.
- **Чтение:** `groups/global/` уже монтируется RO в каждый контейнер как `/workspace/global/`. Значит `/workspace/global/profiles/<slug>.md` читается всеми из коробки (тот же маунт, что `about-sergei.md`).
- **Свой фрагмент** агент видит и как `/workspace/agent/memories/public.md` (пишет), и как `/workspace/global/profiles/<slug>.md` (RO-проекция) — пишет только первый.

### Discovery (критично — «агенты понимают где про что читать»)

1. **`groups/global/profiles/index.md`** — каталог: одна строка на агента «что внутри, когда читать». Проецируется/держится хостом или Jarvis. Пример:
   ```
   - greg.md — здоровье: готовность, восстановление, тренд тела. Читай когда вопрос про энергию/сон/состав тела.
   - gordon.md — питание: таргеты, адерентность. Читай когда про еду/вес/рекомп.
   - payne.md — тренировки: программа, нагрузка, трен-день. Читай когда про фитнес/топливо.
   - scrooge.md — финансы (огрублённо). Читай когда про деньги/траты.
   ```
2. **Общий `groups/INSTRUCTIONS.md` — новый §Публичные профили** (импортится всеми через `@./INSTRUCTIONS.md`, единое место): «Кросс-доменный контекст — в `/workspace/global/profiles/`. Прочитай `index.md`, при вопросе из чужого домена сверься с нужным фрагментом (continuity reflex, как с памятью). Свою сводку держи в `memories/public.md` — обновляй на дневном цикле, хост раздаст остальным.»
3. Каждый агент знает СВОЙ формат `public.md` из своего CLAUDE.md (что публиковать).

### Свежесть vs a2a

- Фрагмент = **ambient-состояние** (обновляется на дневном цикле, читается по запросу). «Каков я сейчас.»
- a2a остаётся для **срочного push'а**: критическая находка Грега → Jarvis немедленно (sick-day, severity critical). «Действуй сейчас.»
- Делёж жёсткий: рутинный кросс-контекст — фрагмент (pull); событие требующее немедленной реакции — a2a (push).

---

## C. Данные состава тела (iOS → Greg-тренд + pull)

iOS добавляет 4 HealthKit-поля: `bodyMass`, `height`, `bodyFatPercentage`, `leanBodyMass` (умные весы Сергея их отдают). Два пути:

### C1. Дневной upload (тренд для Грега)

- **Протокол:** `bodyMass`/`bodyFatPercentage`/`leanBodyMass` → `V2.HealthUpload.Day` (Swift `Protocol/V2.swift:617`) + Zod `HealthUploadDay` (`shared/ios-app-protocol/v2.ts:317`) после `spo2Min`. **Fixture-pinned** — обновить фикстуру (`shared/ios-app-protocol/fixtures/health/`). `height` static → тоже на `Day` (проще, чем на `Body`).
- **Чтение (iOS):** `HealthHistory.swift` — latest-sample reads (паттерн `qHR` стр.287-318), вставка после spo2-блока (~стр.208). Авторизация: `HealthManager.swift:16-31` + `HealthSync.swift:12-21` (+4 типа).
- **Host ingest:** `health-ingest.ts:19` спредит `...d` — новые поля летят в `raw.jsonl` Грега автоматически, host-кода не трогаем.
- **Greg `analyze.js`:** `METRICS` (стр.19-27, ХАРДКОД — +`bodyFatPercentage`,`leanBodyMass`), `CONCERN_UP`+=bodyFat / `CONCERN_DOWN`+=leanMass, новый `buildBodyComp(rows, window=28)` (синтетика: `fatMassKg = bodyMass*bodyFatPercentage/100`, `leanMassKg`, slope за окно), `latest` объект (стр.453-467 хардкод — +поля). Greg CLAUDE.md §Данные — новый блок документирует 3 поля + семантику.
- **Greg публикует** тренд тела в `memories/public.md` (→ `greg.md`) на дневном цикле (`daily-cycle` skill +шаг).

### C2. Pull-снапшот (вес/рост для intake Гордона)

- **iOS:** `HealthManager.swift` +`bodyMass`/`height` props+fetches (latest-sample, паттерн qHR). `AppContextCoordinator.health()` (стр.35-55) +`body_mass_kg`/`height_m` в ответ (freeform JSON, protocol-струк НЕ трогаем).
- Зависит от **A** (фикс гейта) — иначе `request_context` не дойдёт до Гордона.
- Body-fat/lean в pull-снапшот тоже можно (Гордон/Грег on-demand), но для intake достаточно вес+рост.

**Body НЕ идёт в контекст-блок сообщений** (`<context/>` XML — только локация). Только pull + upload.

---

## D. Интеграция Гордона

- **intake** (skill, обновить): вместо вопроса — `request_context(["health"])` → читает `body_mass_kg`/`height_m` → `targets.js --set`. Если pull пуст (нет данных/Watch) — fallback на вопрос. Рост спрашивает один раз только если в Health его нет.
- **Рекомп-вердикт:** Гордон читает `/workspace/global/profiles/greg.md` (тренд тела) → судит «сухая↑/жир↓ при ровном весе = работает». В weekly-итоге.
- **Гордон публикует** `memories/public.md`: таргеты, адерентность (белок-стрик, ккал vs цель). На дневном цикле (`daily` skill +шаг).
- **Payne-контекст:** трен-день Гордон берёт из `payne.md` (углеводы вверх), не из a2a.

---

## E. Реформа a2a (что остаётся push)

Перекрой из плана Фазы 4:
- ❌ Greg→Gordon `bodycomp` a2a → ✅ Гордон читает `greg.md`.
- ❌ Gordon→Greg `nutrition_signal` a2a → ✅ Грег читает `gordon.md`.
- ❌ `nutrition_trend`/`health_trend`→Jarvis push → ✅ Jarvis читает фрагменты для брифа (опц. лёгкий «пинг посмотреть» остаётся).
- ❌ Payne→Gordon `training_day` a2a → ✅ Гордон читает `payne.md`.
- ✅ **Остаётся a2a:** срочные события — Greg критфайндинг/sick-day → Jarvis немедленно; recheck-запросы (Jarvis→Greg «перепроверь X»).

Существующие a2a Грега (`health_trend`/`health_signal`/finding) — не ломать; постепенно дублирующий ambient-слой уходит в фрагменты, срочный остаётся.

---

## Поверхность сборки/деплоя

| Стрим | Что | Деплой |
|-------|-----|--------|
| A | `request_context.ts` гейт + legacy-чистка | **пересборка образа** + редеплой |
| B | host-sweep проекция, `groups/global/profiles/`, INSTRUCTIONS §профили, per-agent `public.md` + CLAUDE.md-инструкции | host: build+restart; group-файлы: scp |
| C1 | iOS protocol+HealthHistory+auth; Greg analyze.js+CLAUDE.md | **iOS-пересборка**; Greg: scp; host: build (shared protocol) |
| C2 | iOS HealthManager+AppContextCoordinator | **iOS-пересборка** |
| D | Gordon intake/daily skills + public.md + CLAUDE.md | scp |

**Зависимости:** D-intake требует A+C2. Рекомп-вердикт требует B+C1. iOS-части (C1+C2) едут ОДНОЙ пересборкой. A — независимый пререквизит (чинит и Грега).

## Фазы для плана

1. **Фикс pull + legacy-чистка** (A) — пересборка образа. Оживляет Грега и Гордона. Независимо полезно.
2. **Система профилей** (B) — host-проекция + конвенция + discovery + per-agent `public.md`/CLAUDE.md. Системный бэкбон. Каждый агент начинает публиковать.
3. **Body-comp данные** (C1+C2) — iOS body-поля (одна пересборка) + Greg тренд тела + Greg публикует в фрагмент.
4. **Гордон-интеграция** (D) — intake-pull, чтение `greg.md`, публикация `gordon.md`, рекомп-вердикт. Закрывает Гордона.

Каждая фаза самостоятельно полезна. 1 — сразу. 2 — системная, не зависит от iOS. 3 — нужна пересборка. 4 — финал.

## Открытые вопросы (провизорно)

- **Проекция-триггер:** host-sweep (60с) vs on-container-exit. Старт — свип (проще). Если лаг важен — добавить on-exit.
- **`jarvis.md`:** заводить ли фрагмент Jarvis или он только читатель. Старт — без него, добавим если понадобится.
- **Формат `public.md`:** свободный markdown с фиксированными заголовками (агенты парсят глазами, не машинно) — каждый агент описывает свой в CLAUDE.md.
- **Дедуп инфы about-sergei vs профили:** профили = текущее состояние (меняется); about-sergei = стабильные факты. Не дублировать вес в about-sergei — он в `greg.md`/pull.
