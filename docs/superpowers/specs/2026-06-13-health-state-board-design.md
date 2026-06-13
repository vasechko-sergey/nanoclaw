# Дизайн: целостность данных здоровья, хранилище SQLite и борд «Состояние»

_Дата: 2026-06-13 · Статус: на ревью_

## 1. Контекст и цель

Утренний бриф и будущая панель в iOS-приложении опираются на дневные агрегаты
здоровья (`raw.jsonl`), которые iOS считает из HealthKit и шлёт на хост, а Greg
(`analyze.js`) трактует. Обнаружены три проблемы, которые решаются вместе, потому
что все лежат на одном слое «данные здоровья → показ»:

- **C — баг целостности.** Глубокий сон за день показывается заниженным
  (06-13: `deepMin=28`, в Health ~58). Кольца и брифы считаются на кривых числах.
- **B — раздутое хранилище.** `raw.jsonl` = 12221 строк на 37 дат (99.7% дублей):
  каждый refresh дослаёт окно дней, хост аппендит.
- **A — нет панели.** Чтобы посмотреть состояние, надо спросить агента. Цель —
  свести энергию/стресс/восстановление/готовность + краткие факты всех агентов в
  одно место в приложении («посмотреть не спрашивая»), как Welltory/Garmin.

Порядок реализации: **C → B → A** (данные сначала корректны, потом компактны,
потом показываем).

## 2. Зафиксированные решения (из брейншторма)

| Тема | Решение |
|---|---|
| Ядро метрик | 4 кольца: **энергия · стресс · восстановление · готовность** |
| Источник чисел | **сервер** — Greg считает, хост отдаёт через GET. Один источник = брифы. |
| Размещение | **полоса 4 колец на дом-экране → тап → полный борд** |
| Состав борда | **все агенты**: кольца здоровья + строки Greg/Gordon/Payne/Scrooge/Jarvis |
| Единообразие | строки агентов одинаковые; графика у Greg нет (уехала в его детальный экран) |
| Взаимодействие | **аккордеон** — тап раскрывает строку на месте (детали из `public.md`) |

---

## 3. C — Фикс окна запроса сна (iOS)

### Root cause (доказан)

`HealthHistory.fetch(from:to:)` (`Services/HealthHistory.swift:85`) запрашивает все
метрики в окне `[start, end]`, где `start = startOfDay(fromDay)`. Сон забирается
`sleepSamplesByWakeDay` (`:401`) предикатом
`HKQuery.predicateForSamples(withStart: start, end: end)` (overlapping по умолчанию)
и бакетится по **дню пробуждения** (`s.endDate`) — атрибуция верная.

Проблема: для дня на **левом крае окна** куски сна, целиком прошедшие ДО полуночи
(первый цикл глубокого сна, ~22:40–23:30), имеют `start/end < start_окна` → не
попадают в выборку → теряются. Куски, пересекающие полночь, возвращаются и
считаются полностью.

Подтверждение из реальных данных VDS (`deepMin` по датам):

```
06-09: {31}      06-10: {59}      06-11: {47→65}   06-12: {49→79}   06-13: {28}
```

День в середине backfill (окно начинается раньше) → вечер кануна в окне → полное
значение (65, 79). День на левом крае → досон потерян → недосчёт (47, 49, 28).
06-13 пока только левый край → 28 вместо ~58.

Тот же класс бага занижает **утренний HRV и SpO₂** (`bucketOvernight`, eveningStart=20,
берёт пробы с 20:00 кануна — а они до `start_окна`) и слегка общий `sleepHours`.

### Фикс

Расширить левую границу запроса для ночных метрик на сутки назад, оставив
бакетинг по дню пробуждения и отбросив дни вне `[from, to]` перед выдачей.

В `fetch(from:to:)`:

```swift
let start = cal.startOfDay(for: fromDay)
// Ночные метрики (сон, утренний HRV, SpO₂) могут начинаться ДО полуночи дня
// пробуждения. Тянем выборку на сутки назад, чтобы досон вечера кануна для
// дня-левого-края не терялся. Атрибуция по дню пробуждения уже корректна;
// дни вне диапазона отбрасываются перед выдачей.
let sleepStart = cal.date(byAdding: .day, value: -1, to: start)!
```

- `sleepSamplesByWakeDay`, overnight-HRV и SpO₂ запросы используют `sleepStart`.
- Дневные/скалярные метрики (шаги, активность, пульс) остаются на `start`.
- Перед `completion` отфильтровать `byDay` по ключам в `[from, to]`
  (дополнительный день-канун не эмитим).

### Тест

`HealthHistoryTests`: синтетические `SleepSampleInput` с глубоким куском
22:50–23:30 (целиком до полуночи) + кусками после полуночи. Прогнать через
`bucketSleepStages`/бакетинг с окном, начинающимся в `startOfDay` дня пробуждения
МИНУС сутки. Ассерт: `deepMin` включает пре-полуночный кусок. Контр-тест на старом
окне (`start` = 00:00 дня) должен показывать недосчёт — фиксируем разницу.

---

## 4. B — Хранилище: `raw.jsonl` → SQLite (дедуп)

### Схема

Файл `groups/<folder>/health/health.db` (там же, где сейчас `raw.jsonl`; уже
смонтирован в контейнер как `/workspace/agent/health/`). Одна таблица:

```sql
CREATE TABLE IF NOT EXISTS health_days (
  date TEXT PRIMARY KEY,         -- 'yyyy-MM-dd', локальная дата пробуждения
  steps INTEGER, activeEnergy REAL, exerciseMinutes INTEGER,
  heartRate INTEGER, restingHeartRate INTEGER, walkingHeartRateAverage INTEGER,
  sleepHours REAL, deepMin INTEGER, remMin INTEGER, coreMin INTEGER,
  awakeMin INTEGER, sleepOnsetMin INTEGER, sleepRegularity REAL,
  hrv REAL, hrvMorning REAL, spo2Avg REAL, spo2Min REAL,
  respiratoryRate REAL, vo2max REAL, wristTempDeviation REAL,
  bodyMass REAL, height REAL, bodyFatPercentage REAL, leanBodyMass REAL,
  ingested_at INTEGER            -- ms эпохи последней записи
);
```

Все поля кроме `date` — nullable (метрики приходят выборочно).

### Кто пишет / читает

- **Хост пишет** (`src/channels/ios-app/v2/health-ingest.ts`): `appendHealthHistory`
  → `upsertHealthDays` — `INSERT ... ON CONFLICT(date) DO UPDATE`. Хост уже имеет
  `better-sqlite3` (центральная БД). **Последняя загрузка побеждает** по дате —
  после фикса C каждая загрузка корректна, так что last-wins безопасен.
- **Контейнер читает** (`analyze.js`, Bun): `bun:sqlite`,
  `SELECT * FROM health_days ORDER BY date`. Заменяет чтение `raw.jsonl`
  (`analyze.js:236` + дубль-функция `:250`).
- `http-handler.ts:loadAllHealthRows` (`:32`, путь sick-day) тоже читает из БД.

### Cross-mount прагма

`health.db` пишется хостом, читается контейнером через смонтированный том —
тот же класс, что session DB. Открывать с `journal_mode=DELETE` (см.
`container/agent-runner/src/db/connection.ts` и `docs/db-session.md`): WAL не
виден через bind-mount стабильно.

### Миграция существующего `raw.jsonl`

Одноразово при старте хоста (паттерн `src/backfill-container-configs.ts`):

1. Если `health.db` нет, а `raw.jsonl` есть — создать БД, прочитать jsonl.
2. На каждую дату взять строку с **максимальным `sleepHours`** (эвристика «самый
   полный backfill» — снимает часть исторического недосчёта C).
3. Upsert в `health_days`.
4. Переименовать `raw.jsonl` → `raw.jsonl.migrated-<ts>` (бэкап, не удаляем).

После миграции для полной коррекции истории — один full re-backfill из iOS с
фикс-кодом C (через `health/requests` refetch на широкое окно): корректные
`deepMin` перезапишут историю по дате.

### Что выпиливаем

`raw.jsonl` как рабочий формат уходит. Бэкап `.migrated-*` остаётся. Все читатели
(`analyze.js`, `loadAllHealthRows`, sick-day) переводятся на `health.db`.

---

## 5. A — Борд «Состояние»

### 5.1 Контракт `public.md` (новое, единое для всех агентов)

`projectPublicProfiles` (`src/public-profiles.ts`) уже копирует
`groups/<folder>/memories/public.md` → `groups/global/profiles/<folder>.md` каждые
~60с (hash-gated, атомарно). Эндпоинт читает оттуда. Вводим лёгкий формат:

```markdown
---
updated: 2026-06-12                                  # дата/время свежести
summary: Сон 6.2ч, пульс покоя 66, вариабельность ровная. Флагов нет.   # свёрнутая строка
levels: {energy: 72, stress: 34, recovery: 81, readiness: 68}           # ТОЛЬКО Greg → кольца
recovery7d: [74, 77, 72, 80, 79, 85, 81]                                # ТОЛЬКО Greg → мини-тренд
---
- Пульс покоя: 66 (норма, медиана ~65)              # body = аккордеон-детали
- Вариабельность: 55 (выше базы)
- Нагрузка: 1.2× — лёгкая
```

- `summary` — строка в свёрнутом виде. `body` (после frontmatter) — детали аккордеона.
- `levels`/`recovery7d` — только у Greg, дают кольца и мини-тренд.
- Каждый агент адаптирует свой skill публикации (`publish` и т.п.), добавив
  `summary:` (и Greg — `levels:`/`recovery7d:`).

### 5.2 Энергия и стресс (новая математика в `analyze.js`, **провизорно**)

Восстановление и готовность Greg уже считает. Добавляем энергию и стресс. Как и
`readiness`, эти метрики **провизорные** (не откалиброваны) — помечаем в публикации,
доверяем в первую очередь восстановлению/аномалиям, константы донастроим по данным.

Входы (последний день + базовые медианы, которые скрипт уже знает): `hrvMorning`
(или `hrv`), `baseline_hrv`, `restingHeartRate`, `baseline_rhr`, `sleepHours`
(`target=7.5`), `deepMin`, `remMin`, `recovery`, `load.ratio`.

```
# Стресс 0-100, ниже = лучше (автономная нагрузка)
s_hrv   = clamp((baseline_hrv - hrvMorning) / baseline_hrv, 0, 1)
s_rhr   = clamp((rhr - baseline_rhr) / baseline_rhr * 2, 0, 1)
s_sleep = clamp((target - sleepHours) / target, 0, 1)
stress  = round(100 * (0.5*s_hrv + 0.3*s_rhr + 0.2*s_sleep))

# Энергия 0-100, выше = лучше (утренний «заряд»)
e_sleep    = clamp(sleepHours / target, 0, 1)
e_quality  = clamp((deepMin + remMin) / 180, 0, 1)
e_recovery = recovery_norm                          # композит → 0..1
e_drain    = clamp(load.ratio - 1, 0, 0.5) / 0.5
energy     = round(100 * clamp(0.35*e_sleep + 0.20*e_quality + 0.45*e_recovery - 0.25*e_drain, 0, 1))
```

Серверное значение энергии = **утренний заряд** (live-утечка в течение дня — это
v2/on-device, см. §7). Перекрытие с восстановлением/готовностью ожидаемо
(Welltory/Garmin тоже пересекаются).

### 5.3 Эндпоинт `GET /ios/state`

В `src/channels/ios-app/v2/http-handler.ts` рядом с `/ios/health/requests`
(bearer-auth, тот же `requireToken`):

- Читает `groups/global/profiles/*.md`.
- Парсит каждый: frontmatter (`updated`, `summary`, `levels`, `recovery7d`) + body.
- Возвращает:

```json
{
  "levels": { "energy": 72, "stress": 34, "recovery": 81, "readiness": 68,
              "recovery7d": [74,77,72,80,79,85,81], "updated": "2026-06-12T08:30:00Z" },
  "agents": [
    { "key": "greg", "title": "Здоровье · Greg", "icon": "🩺",
      "summary": "Сон 6.2ч, пульс покоя 66…", "detail": "- Пульс покоя…\n- …",
      "updated": "2026-06-12" },
    { "key": "gordon", "title": "Питание · Gordon", "icon": "🍽", "...": "..." }
  ]
}
```

- `levels` берётся из `greg.levels` (если нет — кольца показываются «—»).
- Порядок агентов фиксированный (greg, gordon, payne, scrooge, jarvis); агенты без
  `public.md` пропускаются. Добавление/удаление агента не требует правок приложения.
- `icon`/`title` — из небольшой статической карты на хосте по `key`.

### 5.4 iOS

- **`StateModel`** (Codable-зеркало ответа) + **`StateService`** — fetch
  `GET /ios/state` на foreground/открытии экрана (паттерн как health-upload, тот же
  bearer-токен).
- **`RingView`** — переиспользуемое кольцо (conic-прогресс + число + подпись), цвет
  по метрике.
- **Полоса на дом-экране** — 4 `RingView` снизу в `OrbHomeView` (`Views/OrbHomeView.swift`),
  тап → навигация на `StateBoardView`.
- **`StateBoardView`** — хедер из 4 колец (`levels`) + список строк агентов. Тап по
  строке = аккордеон-разворот (рендер `detail` как markdown). Разворот Greg
  дополнительно рисует мини-тренд из `recovery7d` + ссылку «Полный экран ›» (заглушка v2).
- Свежесть: показываем `updated` каждой строки; если `updated` не сегодня — строка
  тусклее, кольца с плашкой «обновлено HH:MM» (честная маркировка, урок брифа).

Список агентов на борде приходит с сервера, не из `AgentIdentity` enum — поэтому
Gordon (которого нет в iOS enum) рендерится без правок приложения.

---

## 6. Фазы и тесты

| Фаза | Состав | Тесты |
|---|---|---|
| **C** | Окно сна в `HealthHistory.swift` + фильтр диапазона | `HealthHistoryTests`: пре-полуночный глубокий кусок попадает в день пробуждения |
| **B** | `health.db` схема, `upsertHealthDays` (host), `analyze.js` чтение через `bun:sqlite`, миграция `raw.jsonl`, перевод sick-day/`loadAllHealthRows` | host vitest: upsert-дедуп; bun:test: чтение БД даёт те же ряды; тест миграции (max-sleepHours на дату) |
| **A1** | Контракт `public.md`; `energy`/`stress` в `analyze.js`; `summary:` в skill-ах публикации агентов; `GET /ios/state` | bun:test: формулы energy/stress; vitest: парсер profiles + форма ответа эндпоинта |
| **A2** | `StateModel`/`StateService`, `RingView`, полоса в `OrbHomeView`, `StateBoardView` (аккордеон, мини-тренд Greg) | Swift: декодирование `StateModel`; smoke-тест борда; рендер аккордеона |

## 7. Что НЕ входит (v2)

- Отдельные детальные экраны на агента (Greg-графики, Gordon лог питания и т.п.).
- On-device live-drain энергии (гибрид: кольца считаются на устройстве в реальном
  времени) — сейчас серверный утренний снапшот.
- Тап секции → чат агента (Greg headless, чата нет).
- Калибровка energy/stress по накопленным данным.

## 8. Риски и открытые вопросы

- **energy/stress не откалиброваны** → плашка «провизорно», приоритет
  восстановлению/готовности/аномалиям.
- **Cross-runtime SQLite** (host `better-sqlite3` пишет, container `bun:sqlite`
  читает) — оба стандартный SQLite-файл; `journal_mode=DELETE` обязателен для
  видимости через bind-mount.
- **Коррекция истории**: миграция берёт max-`sleepHours` на дату (эвристика);
  полная коррекция `deepMin` — отдельным full re-backfill из iOS фикс-кодом C.
- **Свежесть**: днём числа утренние; честная плашка «обновлено HH:MM», тусклая если
  не сегодня.
- **DB-местоположение**: per-agent `groups/<folder>/health/health.db` (а не
  центральная БД) — совпадает с текущим монтированием и держит данные здоровья в
  workspace агента.
