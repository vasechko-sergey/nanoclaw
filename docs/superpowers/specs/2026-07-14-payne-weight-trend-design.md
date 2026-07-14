# Payne: детерминированный тренд веса + предписание (weight-trend.js)

Дата: 2026-07-14 · Агент: payne (фитнес-тренер) · Вариант: **C** (гибрид)

## 1. Проблема

Вся подсистема прогрессии Пейна не работает — трёхстороннее расхождение:

- **`scripts/progression.js`** — CLI `--day-idx`, матчит `s.day_idx` (у сессий нет такого поля — есть `day_name`) → `last` никогда не найден; читает `set.weight` (реальные подходы хранят **`weight_kg`**) → `NaN`. Мёртв.
- **skill `progression`** документирует иной интерфейс (`--session … --out`, вывод `{updates,regressions,stable}`), которого скрипт не реализует.
- И скрипт, и скил пишут в поле `weight_kg_base`, а в `programs/current.json` поле называется **`starting_weight`**.
- `volume-report.js:28` — тот же баг `.weight` вместо `.weight_kg` → тоннаж `NaN`.

Схема сессий/программы уехала после написания кода; код не обновили.

## 2. Цель

Один Bun-скрипт, который **детерминированно, без вызова ЛЛМ** считает по каждому упражнению:

1. **тренд** — оценка 1ПМ (e1RM), наклон кг/нед, текущий рабочий вес, статус;
2. **предписанный вес** на следующий подход — **по объявленному в программе типу прогрессии** (включая понижения: разгрузка, откат).

Пейн потребляет числа: при построении плана (`--all`) и перед тренировкой (`--day`). Вес по программе он видит готовым, переопределяет только по суждению (сигнал травмы/ограничение от Грега). Максимум детерминизма — минимум галлюцинаций веса.

## 3. Источники данных

**`sessions/YYYY-MM-DD.json`** (per-person, RW):
```json
{ "date":"2026-07-14", "week":4, "day_name":"Верх А",
  "exercises":[ { "exercise_slug":"…",
    "sets":[ {"weight_kg":60,"reps":8,"reps_in_reserve":2,"ts":"…"} ] } ] }
```
Разминка/кардио → `sets: []` (пропускаем). Импорт из антитренера — `…-at-<id>.json`, синтетика — `baseline*.json` (входят в окно как обычные сессии).

**`programs/current.json`** (per-person, RW): `current_week`, `weekly_intensity_pattern[]` (per week: `weight_modifier`, `set_modifier`, `target_rir_override`), `days.<split>.exercises[]` (per ex: `starting_weight`, `target_reps` строка-диапазон "8-10", `target_rir`, `target_sets`).

**Новый блок `progression`** (см. §6) — объявляет тип. Отсутствует → скрипт даёт только тренд.

## 4. Метрика тренда (устойчива к разгрузке)

Per set:  `effReps = min(reps + reps_in_reserve, 12)` (кэп — Эпли врёт на высоких повторах)
          `setE1RM = weight_kg × (1 + effReps/30)`  (Эпли, RIR-скорректированная)
Per session: точка = **max setE1RM по рабочим подходам** (лучший подход, оценка надёжнее у отказа).

Почему e1RM, не сырой вес: запас нормализует усилие → сет разгрузки (лёгкий, запас 4) проецируется в тот же 1ПМ, что тяжёлый (запас 1). Сырой вес на разгрузке падает → ложный «откат». e1RM — нет.

Окно = последние `N` (по умолч. **6**) сессий с этим упражнением (по дате, убыв.). Почему не вся история: 38 сессий пересекают смену залов + рекалибровки (жим ногами «с платформой», Шри-Ланка) — старые абсолютные веса несравнимы.

`< 3` точек → `status:"insufficient"`, тренд `null`.
Иначе: x = (дата − дата₀)/7 нед; наклон МНК e1RM по x → `e1rm_trend_kg_per_wk`.
Статус: `> +0.25` → `progressing`; `< −0.25` → `regressing`; иначе `stalled`.

## 5. Предписание (если `progression`-блок есть)

Пер упражнение, текущая неделя `W = current_week`:
```
weekMod = pattern[W-1].weight_modifier
weekRir = pattern[W-1].target_rir_override ?? ex.target_rir
inc     = progression.increment_kg[slug] ?? progression.default_increment_kg ?? 2.5
topRange, botRange = разбор ex.target_reps ("8-10" → 10, 8)

lastReal = свежайшая сессия с этим упражнением (рабочие подходы непусты),
           чья неделя НЕ разгрузка (weight_modifier ≥ 1)   // разгрузка не двигает якорь

anchor = ex.starting_weight                         // база плана (эквивалент недели-1)
если lastReal:
  allHitTop = все рабочие подходы reps ≥ topRange
  anyFail   = есть подход (rir==0 И reps < botRange)
  allHitTop → newAnchor = anchor + inc; advanced=true
  anyFail   → newAnchor = anchor − inc; regression=true
  иначе     → newAnchor = anchor                    // держим, добираем повторами
иначе newAnchor = anchor

prescribed_next_kg = round_to(newAnchor × weekMod, inc)   // ближайшее кратное inc
prescribed_rir     = weekRir
```

Понижения обработаны детерминированно: **разгрузка** (`weekMod` 0.9) и **откат** (`anyFail` → −inc). Иное понижение (ручная смена/техника) — суждение Пейна поверх.

Якорь = `starting_weight` (источник плана), решение о бампе — из фактической последней НЕ-разгрузочной сессии. Расхождение факта и предписания видно в выводе → сигнал Пейну рекалибровать `starting_weight` руками (он уже так делает: `notes: "рекалибровано 2026-07-10"`).

Скрипт **не пишет** в программу — только считает. Применение `newAnchor`→`starting_weight` делает skill `progression` (как и раньше). Чистый калькулятор, I/O только в CLI-обёртке.

## 6. Схема `progression`-блока (в `programs/current.json`)

```json
"progression": {
  "type": "double",
  "wave": true,
  "default_increment_kg": 2.5,
  "increment_kg": { "zhim-nogami": 5, "yagodichnyy-most": 5,
                    "razgibanie-nog-v-trenazhere-sidya": 5, "razvedenie-nog-v-trenazhere": 5 }
}
```
`type:"double"` — двойная прогрессия (диапазон повторов → бамп). `wave:true` — модулировать `weekly_intensity_pattern`. Будущие типы (`linear`) — новая ветка в §5. Блок кладётся в программу владельца сейчас; skill `workout-mode` §создание программы эмитит его для всех будущих программ → кросс-пользовательски.

## 7. Вывод и CLI

```bash
bun /workspace/agent/scripts/weight-trend.js \
  [--all | --day <split_key> | --exercise <slug>] \
  [--program programs/current.json] [--sessions-dir sessions] [--window 6]
```
`--all` (по умолч.) — вся программа (построение плана). `--day upper_a` — упражнения дня (перед тренировкой). Печатает JSON-массив:

```json
{ "exercise_slug":"zhim-shtangi-lezha-shirokim-hvatom",
  "n":6, "working_weight_kg":60, "e1rm_kg":78.5,
  "e1rm_trend_kg_per_wk":0.8, "status":"progressing",
  "last":{"date":"2026-07-14","top_weight_kg":60,"top_reps":8,"min_rir":2},

  "prescribed_next_kg":62.5, "prescribed_rir":1, "advanced":true,
  "progression":"double+wave",
  "rationale":"верх диапазона взят во всех подходах при запасе≤цель → +2.5; неделя тяжёлая ×1.05" }
```
Блок предписания (`prescribed_*`, `advanced`, `progression`, `rationale`) присутствует **только** если в программе есть `progression`. Иначе — деградация в тренд-только (чистый вариант C, обратно-совместимо).

**Исключения/устойчивость:** упражнения-разминка (`target_sets: null` или пустой `target_reps`) в отчёт не входят. Подходы без `weight_kg`/`reps` (битая/частичная запись) пропускаются; если у упражнения не осталось валидных подходов в окне — `status:"insufficient"`, предписание не считается.

## 8. Что заменяет / чинит

| Артефакт | Действие |
|----------|----------|
| `scripts/schema.js` | **новый** — единственный источник имён полей + валидирующие парсеры + аксессоры (§12) |
| `scripts/weight-trend.js` | **новый** — тренд+предписание, весь доступ к данным через `schema.js` |
| `scripts/selfcheck.js` | **новый** — прогон потребителей на реальных данных, громкий отказ (§12) |
| `scripts/progression.js` | удалить (надмножество в новом скрипте) |
| skill `progression/SKILL.md` | переписать под `weight-trend.js`; применять к `starting_weight`; НЕ дублировать поля/ключи — ссылка на `--help` (§12 слой 3) |
| `scripts/volume-report.js` | переписать на `schema.js` (чинит `.weight`→`.weight_kg`); интерфейс без изменений |
| skill `workout-mode` | §создание программы — эмитить `progression`-блок |
| `programs/current.json` (владелец) | добавить `progression`-блок сейчас |

## 9. Поверхности деплоя

- **Скрипт + скилы** — кросс-пользовательские, shared-mount: `groups/payne/{scripts,skills}` (источник) → scp `agents/payne/{scripts,skills}` (VDS). Живут для всех пользователей Пейна.
- **`progression`-блок в `current.json`** — per-person data: `data/user-memory/owner/payne/programs/current.json` (VDS). У каждого пользователя своя программа; блок для будущих эмитит `workout-mode`.
- Скрипты/скилы live-mounted → без перерождения контейнера. Правок CLAUDE.md/INSTRUCTIONS нет.

## 10. Тесты (`bun:test`, чистые функции, фикстуры реальных слагов)

- формула e1RM + кэп effReps на 12;
- **устойчивость к разгрузке**: разгрузочная сессия не переводит статус в `regressing`;
- знак наклона на синтетике рост/падение; `insufficient` при <3 точек;
- двойная прогрессия: allHitTop→+inc, anyFail→−inc, середина→hold;
- волна: разгрузка → prescribed = round(anchor×0.9, inc);
- деградация: нет блока → нет `prescribed_*`, тренд есть;
- окно: используются только последние N.

## 11. Защита от будущего дрейфа

Корень дрейфа: неявная схема (3 копии правды: данные / скрипты / проза скила), тихий отказ (`undefined`→`NaN`/`null` без throw), много писателей (iOS-конверт, `chat-log`, импорт) без координации. Писатель хранилища — ЛЛМ + iOS, запись схемо-рыхлая → защита на ЧТЕНИИ.

**Слой 1 — `scripts/schema.js` (одна правда + валидация).** Единственное место с именами полей. Экспорт: `parseSession(raw,{path})`, `parseProgram(raw)`, аксессоры `workingSets(ex)`, `isWarmup(planEx)`, `topSet(ex)`, `e1rm(set,cap=12)`, `repRange(planEx)`, `weekPattern(prog,week)`. Все скрипты импортируют, к сырым `.weight_kg` не лезут. Переименование поля = одна правка.

Валидация — **два уровня**, чтобы отличить дрейф от легаси:
- **Структурный дрейф → throw.** Систематическая пропажа поля = переименование. Правило: сессия имеет подходы, но **ни один** не содержит `weight_kg` (или `reps`) → `throw "session <path>: 0/N sets have weight_kg — schema drift?"`. Это громкий сигнал ровно на баг, что мы ловим.
- **Спорадический пробел → skip.** Отдельный битый/частичный подход (старый импорт без `reps_in_reserve`) — пропускается, считается; не осталось валидных → `status:"insufficient"`. Легаси не роняет прогон.

**Слой 2 — `scripts/selfcheck.js` (громкий отказ на расписании).** Грузит реальную `current.json` + свежайшую сессию, гоняет `weight-trend --all` и `volume-report`, ассертит: каждое не-разминочное упражнение → числовой `e1rm` ИЛИ `status:"insufficient"` (не null-из-краха); тоннаж конечен. Отказ → exit≠0 + строка. Вешается на суточный таск Пейна → дрейф всплывает алертом владельцу за сутки, не «через месяц».

**Слой 3 — скилы не дублируют контракт.** `progression/SKILL.md` не перечисляет поля/ключи вывода — ссылается на `bun weight-trend.js --help` и `schema.js`. Минус одна дрейфующая копия правды.

Пропущено (YAGNI): версионный штамп `"schema":N`, запись-тайм JSON Schema — хранилище маленькое, одновладельческое, ЛЛМ-писателя на запись не заассертишь. Слои 1+2 покрывают реальные режимы отказа.

## 12. Шаги реализации

1. `scripts/schema.js` — парсеры/аксессоры/валидация двух уровней (§11 слой 1).
2. `scripts/weight-trend.js` — чистый модуль (`computeTrend`, `computePrescription`, `buildReport`) через `schema.js` + CLI (`import.meta.main`, `--help`).
3. `scripts/weight-trend.test.js` — фикстуры + кейсы §10 + кейсы валидации схемы (дрейф→throw, легаси→skip); `bun test`.
4. `scripts/volume-report.js` — переписать на `schema.js` (чинит `weight_kg`).
5. `scripts/selfcheck.js` + повесить на суточный таск.
6. Переписать skill `progression/SKILL.md` (слой 3, без дублей).
7. Правка skill `workout-mode` §создание программы (эмит блока).
8. Удалить `progression.js`.
9. Добавить `progression`-блок в программу владельца.
10. Деплой: scp shared (`schema.js`, `weight-trend.js`, `selfcheck.js`, `volume-report.js`, скилы) в `agents/payne/`; блок — в per-person `current.json`.
11. Верификация: прогон `--day upper_a` + `selfcheck` на реальных данных владельца, глазами сверить с логами.
