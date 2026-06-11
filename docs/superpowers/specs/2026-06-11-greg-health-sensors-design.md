# Дизайн: расширение сенсорики Грега (health-analyzer)

- **Дата:** 2026-06-11
- **Статус:** одобрено (дизайн), готово к плану реализации
- **Скоуп:** Variant B (реальные дыры, full-stack) + Readiness 0-100
- **Затрагивает:** iOS-приложение, протокол ios-app v2, host-ingest, `analyze.js`, Greg CLAUDE.md

## 1. Контекст и проблема

Greg (`groups/greg/`) — автономный headless-аналитик здоровья Сергея. Раз в день гоняет `scripts/analyze.js` по `health/raw.jsonl` (дневные агрегаты из HealthKit), флагует аномалии (robust MAD + mod-z, 3-дневное устойчивое окно), шлёт findings Jarvis и `health_signal` Пейну (фитнес-тренер).

Сергей спросил Грега «чего тебе не хватает». Ответ (VDS, session `sess-1780961542902-w1p5n2`, seq=137) — 6 пунктов. Проверка против реальных данных (`raw.jsonl`, вся цепочка iOS→host→скрипт) показала, что **самооценка Грега неточна**:

| Greg просил | Реальность (по данным) | Вердикт |
|---|---|---|
| 1. Фазы сна (deep/REM/light/awake) | `sleepByDay` суммирует все asleep-стадии в одно `sleepHours` — стадии есть в HealthKit, но схлопываются | **реальная дыра** |
| 2. Утренний HRV (RMSSD) | `hrv` = SDNN среднее за весь день, не окно пробуждения. Apple даёт **SDNN, не RMSSD** | **реальная дыра** + корректировка |
| 3. Ночной SpO2 | `.oxygenSaturation` не запрашивается и не авторизован | **реальная дыра** (под gate-проверку, см. §8) |
| 4. Температура запястья | течёт, ~42% дней (sparse) — лимит Apple S8+, не баг | частично, плумбинг ок |
| 5. Субъективная оценка | нет UI — новый ввод | дыра (новая поверхность) — **out of scope** |
| 6. VO2max | **0 строк из 7347. Wired в коде+протоколе+METRICS, данных НОЛЬ** — силовые не генерят vo2max | мнимая |

**Бонус-находки:** `respiratoryRate` (~56% строк) и `walkingHeartRateAverage` (~53%) уже текут и уже в `METRICS` — детектор по ним бежит, но CLAUDE.md их почти не трактует. Поток данных проверен по числу вхождений ключей в `raw.jsonl` (файл с occurrence-append; `analyze.js` дедупит по дате — абсолютные числа = строки, не уникальные дни, но соотношения показательны; `vo2max=0` — однозначно).

**Реальные дыры, которые закрываем:** фазы сна, утренний HRV, ночной SpO2 (все три — iOS-работа). Плюс рескрипт: дотрактовать существующее, upgrade детекции, readiness score.

## 2. Зафиксированные решения

- **Scope B:** sleep phases + morning HRV + SpO2 в один full-stack заход (iOS + протокол + фикстуры + скрипт). **Без** субъективного ручного ввода.
- **Глубина скрипта:** богатая — новые сенсоры + upgrade recovery-композита + training-load aware + регулярность сна + **readiness 0-100**.
- **Daily pulse:** оставить как есть (Greg молчит когда чисто; `health_signal` Пейну остаётся). Ежедневный сигнал Сергею НЕ добавляем.
- **Дефолты форм сенсоров** (одобрены):
  - Фазы сна: `deepMin / remMin / coreMin / awakeMin` (минуты), `sleepHours` остаётся (= deep+rem+core).
  - Утренний HRV: `hrvMorning` = среднее SDNN за окно сна прошлой ночи (bucket на день пробуждения); дневной `hrv` остаётся fallback.
  - SpO2: `spo2Avg` + `spo2Min` за окно сна (min ловит десатурацию).
  - vo2max: поле оставляем, но в CLAUDE.md снимаем статус сигнала пока 0 данных.
- **Источник нагрузки:** новый `health/workouts.jsonl` (Greg дописывает при `workout_done` от Пейна), скрипт читает — числовая работа в скрипте, не в LLM.
- **Readiness** = представление upgraded-recovery-композита в шкале 0-100 + поправка на acute-нагрузку. Один источник истины (компоненты), два представления (recovery z-score внутренний, readiness 0-100 человекочитаемый).

## 3. Архитектура и поток данных

```
iOS HealthHistory.swift ──upload──> http-handler (zod) ──> health-ingest (...d) ──> raw.jsonl ──> analyze.js ──> Greg(LLM) ──a2a──> Jarvis/Payne
       (produce)            (validate, MUST allow new)    (passthrough, no change)  (+workouts.jsonl)  (score)    (interpret)
```

Пять слоёв изменений: протокол → iOS-сбор → (host без кода) → анализатор → инструкции/wiring Грега.

## 4. Слой 1 — Протокол

Файлы: `shared/ios-app-protocol/v2.ts`, зеркало `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift`, `shared/ios-app-protocol/fixtures/*.json` + контракт-тесты.

Новые **опциональные** поля на `HealthUploadDay` (как `vo2max` — нет данных → ключ опущен; `analyze.js series()` пропускает отсутствующее):

| Поле | Zod | Смысл |
|---|---|---|
| `deepMin` | `z.number().int().nonnegative().optional()` | минуты глубокого сна |
| `remMin` | то же | минуты REM |
| `coreMin` | то же | минуты core/light |
| `awakeMin` | то же | минуты бодрствования внутри окна сна (фрагментация) |
| `sleepOnsetMin` | `z.number().int().optional()` | начало сна, минут от локальной полуночи (`<0` = до полуночи) |
| `hrvMorning` | `z.number().int().nonnegative().optional()` | SDNN среднее за окно сна, мс |
| `spo2Avg` | `z.number().nonnegative().optional()` | ночное насыщение O₂, среднее, % |
| `spo2Min` | `z.number().nonnegative().optional()` | ночное насыщение O₂, минимум, % |

**Критично:** zod по умолчанию срезает неизвестные ключи на `.parse()`. Без добавления в схему новые поля iOS не доживут до `health-ingest`. Поэтому протокол-изменение load-bearing, не косметика типов.

`sleepHours` сохраняется для непрерывности и совместимости со старыми строками. Обновить Swift-зеркало `V2.swift` + фикстуры + контракт-тест (TS↔Swift).

## 5. Слой 2 — iOS-сбор

Файлы: `ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift` (дневные агрегаты → `raw.jsonl`), `HealthManager.swift` (авторизация).

- `HealthManager.requestAndFetch()`: добавить `HKQuantityType(.oxygenSaturation)` в набор `types`.
- `sleepByDay` → раскрыть по стадиям: вместо суммы asleep копить раздельно по `HKCategoryValueSleepAnalysis`:
  - `.asleepDeep` → `deepMin`, `.asleepREM` → `remMin`, `.asleepCore`/`.asleepUnspecified` → `coreMin`, `.awake` (внутри окна) → `awakeMin`.
  - `sleepOnsetMin` = старт самого раннего asleep-сэмпла окна, в минутах от локальной полуночи дня пробуждения.
  - `sleepHours` = (deep+rem+core)/60, как раньше.
- Новый запрос `hrvMorning`: SDNN-сэмплы (`.heartRateVariabilitySDNN`) с timestamp внутри окна сна ночи, оканчивающейся на этот день → среднее, мс. (Дневной `hrv` через `HKStatisticsCollectionQuery discreteAverage` остаётся как есть.)
- Новый запрос SpO2: `.oxygenSaturation` за окно сна → `spo2Avg` (среднее) и `spo2Min` (минимум). Единица — доля (0..1) у HealthKit; конвертировать в % (× 100).
- Всё graceful: нет устройства/данных/авторизации → поле опущено (S6+ для SpO2; регион-ограничения возможны — см. §8).
- Окно сна переиспользовать существующее (вечер предыдущего дня → полдень) из текущего `fetchSleep`/`sleepByDay`.

## 6. Слой 3 — Host-ingest

**Изменений кода нет.** `src/channels/ios-app/v2/health-ingest.ts` уже делает `{ ...d, ingested_at }` — новые поля льются автоматически. Единственная зависимость — zod-схема из §4 (иначе поля срезаются до ingest). `sick-day.ts` использует `HealthUploadDay` аддитивно, не ломается (SpO2 в sick-day-детектор этот заход НЕ включаем — см. §11 out of scope).

## 7. Слой 4 — Анализатор `analyze.js`

Файлы: `groups/greg/scripts/analyze.js`, `groups/greg/scripts/analyze.test.js` (Bun).

### 7.1 Новые метрики в детекторе
- `METRICS +=` `deepMin`, `remMin`, `awakeMin`, `hrvMorning`, `spo2Min`. (`coreMin`, `spo2Avg`, `sleepOnsetMin` — входы derived-логики, не самостоятельные аномалии.)
- Синтетические метрики строятся отдельно и тоже входят в `METRICS`/`CONCERN`: `recovery` (есть, CONCERN_DOWN), `sleepRegularity` (§7.3, CONCERN_UP). `readiness` (§7.5) — выход, НЕ детектируется как аномалия.
- `CONCERN_DOWN +=` `deepMin`, `remMin`, `hrvMorning`, `spo2Min` (падение = плохо).
- `CONCERN_UP +=` `awakeMin` (рост фрагментации = плохо).

### 7.2 Upgrade recovery-композита (`buildRecovery`)
Текущие компоненты: `hrv(+)`, `restingHeartRate(−)`, `sleepHours(+)`, `wristTempDeviation(−)`. Добавить:
- `hrvMorning(+)` — **приоритет над дневным `hrv`**: если `hrvMorning` присутствует, использовать его вместо `hrv` в композите; дневной `hrv` — fallback.
- `deepMin(+)`, `remMin(+)` — несущие восстановление стадии.
- `spo2Min(+)` — ночная десатурация тянет восстановление вниз.
- Сохранить требование «≥2 компонента присутствуют»; пере-развесить, чтобы один отсутствующий сенсор не ломал композит.

### 7.3 Регулярность сна (derived)
- `sleepRegularity` — синтетическая метрика (как `recovery`): для каждого дня = стандартное отклонение `sleepOnsetMin` за трейлинг-окно 14д. Высокое значение = нерегулярный циркадный ритм.
- Считается единым способом: построить ряд `sleepRegularity` по дням, добавить в `METRICS` + `CONCERN_UP` (рост разброса = плохо) и прогнать через тот же детектор аномалий (MAD + mod-z, устойчивое окно), что и остальные метрики. Отдельного флаг-механизма не вводим.

### 7.4 Training-load awareness
- Источники: `health/workouts.jsonl` (`{date, tonnage_kg, duration_min, rir}` от Пейна) + `raw.jsonl workouts[]` (HK: `durationMin`, `energyKcal`, `avgHR`). Мердж по дате; tonnage приоритетнее, energy — прокси при отсутствии.
- `acuteLoad` = сумма нагрузки за последние 3-7д; `chronicLoad` = скользящее среднее за ~28д; `loadRatio = acute/chronic` (ACWR-подобно, но мягко).
- Применение в детекторе аномалий recovery/hrv:
  - высокий `acuteLoad` + просадка HRV/recovery в ожидаемых пределах → **подавить** (не алармить, известная реакция на нагрузку). Реализация: понизить severity или пометить `expected_post_load: true`.
  - высокая нагрузка + деградация восстановления держится >N дней → **эскалация** severity.

### 7.5 Readiness score 0-100
- `readiness` = логистическая (или клампленная линейная) карта upgraded-recovery-композита (z-score), скорректированная `loadRatio`.
- Ориентир: `readiness = clamp(round(50 + K * recovery_z - loadPenalty), 0, 100)`, где `K` и `loadPenalty` подбираются TDD (стартовые: `K≈12`, `loadPenalty` пропорционально превышению `loadRatio>1.3`). Константы финализируются в реализации под фикстуры.
- Бэнды → `health_signal.level`: `≥70 green`, `50..69 yellow`, `<50 red`.
- Вывод: в `normal`-mode результате `analyze.js` (поле `readiness` рядом с `anomalies`) для Грега; Greg передаёт в `health_signal` Пейну и может цитировать в finding.
- `recovery` (внутренний z-композит, детектируемый как аномалия) и `readiness` (0-100 представление) делят одни компоненты — один источник истины.

### 7.6 Morning HRV приоритет
Во всех формулах (recovery, readiness, sick-day-совместимость) `hrvMorning` предпочтительнее дневного `hrv`; дневной — fallback при отсутствии.

## 8. SpO2 verification gate — ПРОЙДЕН

**Разрешено (2026-06-11):** Сергей проверил Health app — **Blood Oxygen пишется постоянно**. Cardio Fitness (vo2max) — считается редко, что подтверждает находку `vo2max=0`.

Следствия:
- **SpO2-детекцию (`spo2Min`) и вклад в recovery включаем без оговорок** — данные реально текут.
- **vo2max** — поле/ряд оставляем (изредка может появиться), но статус сигнала в CLAUDE.md не активируем, пока покрытие околонулевое (как и решено в §2/§9).
- **Build-time счётчик сэмплов** (`oxygenSaturation` за 14д в debug-лог iOS) оставляем как дешёвый sanity-check после первого сбора — но это уже не блокер, а подтверждение.
- Скрипт graceful к отсутствию любого сенсора в любом случае (`series()` пропускает отсутствующее).

## 9. Слой 5 — Greg wiring и CLAUDE.md

Файл: `groups/greg/CLAUDE.md`.

- **§ Данные:** документировать новые поля (фазы, `hrvMorning`, SpO2) и их трактовку:
  - deep/REM — несущие восстановление стадии; `awakeMin` в окне = фрагментация.
  - morning HRV vs дневной — почему чище.
  - SpO2-десатурация объясняет «спал, но восстановления нет» (наблюдение, не диагноз; апноэ/высота/болезнь — «стоит проверить»).
  - `readiness` 0-100 + как подавать (House-тон) + маппинг бэндов.
  - training-load: ожидаемая просадка после тренировки vs тревожная.
  - **vo2max — снять статус сигнала пока 0 данных. Убрать упоминание RMSSD — у Apple SDNN.**
- **§ Связка с Пейном:** при `workout_done` дописывать `{date, tonnage_kg, duration_min, rir}` в `health/workouts.jsonl` (плюс к заметке в `state.md`). В `health_signal` добавить `readiness`.

## 10. Тесты и деплой

- **Контракт:** обновить `shared/ios-app-protocol/fixtures/*.json` + контракт-тест (TS↔Swift зеркало).
- **Скрипт:** `analyze.test.js` (Bun) — кейсы: раскрытие фаз, приоритет morning HRV, SpO2-десатурация в recovery, sleepRegularity, подавление аномалии по нагрузке, эскалация, readiness-бэнды.
- **Деплой:**
  - host: `pnpm run build` + git pull на VDS (протокол/zod изменились) → рестарт.
  - скрипт + CLAUDE.md: scp `groups/greg/` на VDS (live-mounted, без пересборки образа; правки CLAUDE.md живому агенту — kill контейнер + сброс continuation, см. память `feedback_agent_instruction_reload`).
  - iOS: `xcodegen generate` (если новые файлы) + build + установка на устройство Сергея; затем рефетч истории (последние 14д) дольёт новые поля.
- **Зависимости:** новых пакетов нет (zod есть; iOS/скрипт без новых deps) → supply-chain gate (`minimumReleaseAge`) не трогаем.

## 11. Out of scope (отложено)

- Субъективный утренний чек-ин (energy/soreness): новый iOS UI + envelope + ingest. Отдельный под-проект.
- Ежедневный pulse Сергею когда чисто (оставили текущее молчание).
- SpO2 как 4-й сигнал sick-day-детектора (`sick-day.ts`) — синергия на потом.
- Продвинутая детекция: формальный ACWR-движок, change-point на медленных метриках, недельный дайджест.

## 12. Открытые вопросы / риски

- ~~**SpO2-доступность**~~ — **снят** (см. §8): Сергей подтвердил, Blood Oxygen пишется постоянно.
- **Readiness-константы** (`K`, `loadPenalty`, бэнды) — финализируются TDD под фикстуры; стартовые значения в §7.5.
- **Сэмпл-наличие morning HRV/фаз** — зависит от ношения часов ночью; всё graceful, но при систематическом отсутствии стоит сообщить Сергею (не молчать как с vo2max).
- **Порядок реализации:** 1) протокол (фундамент) → 2) iOS-сбор → 3) скрипт+тесты → 4) CLAUDE.md + workouts.jsonl → 5) деплой (host + iOS + greg).
