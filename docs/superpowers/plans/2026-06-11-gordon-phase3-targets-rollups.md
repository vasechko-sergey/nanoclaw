# Gordon Agent — Phase 3 (Targets & Daily Rollups) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Gordon recomp targets (calories + protein/fat/carbs from the user's body stats) and a daily rollup that answers "did I hit my macros today?" — then an evening summary in Ramsay's voice.

**Architecture:** Extend the Phase-2 Bun script layer. `db.js` gains `profile` + `targets` tables. `targets.js` computes recomp targets (Mifflin-St Jeor BMR × activity → TDEE; protein/fat by bodyweight, carbs fill the rest). `daily-rollup.js` sums today's meals from `meals.db` and compares to targets. The `intake` skill captures height/weight/activity once; the `daily` skill runs the rollup and Gordon delivers the verdict directly to Сергей (no a2a yet — Jarvis/Greg/Payne wiring is Phase 4).

**Tech Stack:** Bun, `bun:sqlite`, `bun:test`. No external deps.

**Spec:** [docs/superpowers/specs/2026-06-11-gordon-nutrition-agent-design.md](../specs/2026-06-11-gordon-nutrition-agent-design.md) · **Prereq:** Phase 2 deployed (`meals.db`, scripts). Known: Сергей is male, born 1985 (age 40); height/weight captured at intake.

---

## Scope note

Phase 3 = targets + daily rollup + intake + evening summary, **all within Gordon** (delivered to Сергей directly). **Deferred to Phase 4:** `nutrition_trend` → Jarvis and every other a2a contract (Greg/Payne), body-comp, `weekly-report.js` — they belong with the consolidated team wiring. Don't build a2a here.

All files under `groups/gordon/` (gitignored — scp deploy, no git commits). Bun tests: `cd groups/gordon && bun test scripts/`.

## File Structure

| File | Create/Modify | Responsibility |
|------|---------------|----------------|
| `groups/gordon/scripts/db.js` | Modify | Add `profile` + `targets` tables + `getProfile`/`setProfile`/`getTargets`/`setTargets` |
| `groups/gordon/scripts/db.test.js` | Modify | Profile/targets round-trip tests |
| `groups/gordon/scripts/targets.js` | Create | Compute recomp targets from profile; `--set` writes profile + targets |
| `groups/gordon/scripts/targets.test.js` | Create | BMR/TDEE/macro math tests |
| `groups/gordon/scripts/daily-rollup.js` | Create | Sum a day's meals vs targets |
| `groups/gordon/scripts/daily-rollup.test.js` | Create | Rollup + vs-target + protein_hit tests |
| `groups/gordon/skills/intake/SKILL.md` | Create | Capture height/weight/activity once → `targets.js --set` |
| `groups/gordon/skills/daily/SKILL.md` | Create | Evening rollup → Ramsay summary; schedule it |
| `groups/gordon/skills/index.md` | Modify | List intake + daily |
| `groups/gordon/CLAUDE.md` | Modify | Wire intake/daily, targets data, evening schedule |

---

## Task 1: extend db.js with profile + targets

**Files:**
- Modify: `groups/gordon/scripts/db.js`
- Modify: `groups/gordon/scripts/db.test.js`

- [ ] **Step 1: Write the failing tests**

Append to `groups/gordon/scripts/db.test.js`:

```javascript
import { getProfile, setProfile, getTargets, setTargets } from "./db.js";

test("profile round-trips (single row)", () => {
  const db = openMealsDb(":memory:");
  expect(getProfile(db)).toBeNull();
  setProfile(db, { height_cm: 180, weight_kg: 80, age: 40, sex: "m", activity: 1.55, goal: "recomp" });
  const p = getProfile(db);
  expect(p.height_cm).toBe(180);
  expect(p.goal).toBe("recomp");
  setProfile(db, { height_cm: 180, weight_kg: 78, age: 40, sex: "m", activity: 1.55, goal: "recomp" });
  expect(getProfile(db).weight_kg).toBe(78); // upsert, still one row
});

test("targets round-trip (single row)", () => {
  const db = openMealsDb(":memory:");
  expect(getTargets(db)).toBeNull();
  setTargets(db, { kcal: 2600, protein_g: 160, fat_g: 72, carb_g: 310, basis: "mifflin x1.55", provisional: 1 });
  const t = getTargets(db);
  expect(t.kcal).toBe(2600);
  expect(t.protein_g).toBe(160);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd groups/gordon && bun test scripts/db.test.js`
Expected: FAIL — `getProfile is not a function` (not exported yet).

- [ ] **Step 3: Implement in `db.js`**

In `initSchema`, add the two tables inside the existing `db.exec(\`…\`)` block (after the `meal_items` table, before the indexes):

```javascript
    CREATE TABLE IF NOT EXISTS profile (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      height_cm REAL, weight_kg REAL, age INTEGER, sex TEXT, activity REAL, goal TEXT, updated_at TEXT
    );
    CREATE TABLE IF NOT EXISTS targets (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      kcal REAL, protein_g REAL, fat_g REAL, carb_g REAL, basis TEXT, provisional INTEGER, updated_at TEXT
    );
```

Then append these exported functions at the end of `db.js`:

```javascript
export function getProfile(db) {
  return db.query("SELECT * FROM profile WHERE id = 1").get() ?? null;
}

export function setProfile(db, p) {
  db.query(`
    INSERT INTO profile (id, height_cm, weight_kg, age, sex, activity, goal, updated_at)
    VALUES (1,$height_cm,$weight_kg,$age,$sex,$activity,$goal,$updated_at)
    ON CONFLICT(id) DO UPDATE SET
      height_cm=$height_cm, weight_kg=$weight_kg, age=$age, sex=$sex,
      activity=$activity, goal=$goal, updated_at=$updated_at
  `).run({
    $height_cm: p.height_cm ?? null, $weight_kg: p.weight_kg ?? null, $age: p.age ?? null,
    $sex: p.sex ?? null, $activity: p.activity ?? null, $goal: p.goal ?? null,
    $updated_at: p.updated_at ?? new Date().toISOString(),
  });
}

export function getTargets(db) {
  return db.query("SELECT * FROM targets WHERE id = 1").get() ?? null;
}

export function setTargets(db, t) {
  db.query(`
    INSERT INTO targets (id, kcal, protein_g, fat_g, carb_g, basis, provisional, updated_at)
    VALUES (1,$kcal,$protein_g,$fat_g,$carb_g,$basis,$provisional,$updated_at)
    ON CONFLICT(id) DO UPDATE SET
      kcal=$kcal, protein_g=$protein_g, fat_g=$fat_g, carb_g=$carb_g,
      basis=$basis, provisional=$provisional, updated_at=$updated_at
  `).run({
    $kcal: t.kcal, $protein_g: t.protein_g, $fat_g: t.fat_g, $carb_g: t.carb_g,
    $basis: t.basis ?? null, $provisional: t.provisional ?? 1,
    $updated_at: t.updated_at ?? new Date().toISOString(),
  });
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd groups/gordon && bun test scripts/db.test.js`
Expected: PASS (5 tests: 3 original + 2 new).

- [ ] **Step 5: On-disk only** (gitignored).

---

## Task 2: targets.js (recomp targets)

**Files:**
- Create: `groups/gordon/scripts/targets.js`
- Create: `groups/gordon/scripts/targets.test.js`

- [ ] **Step 1: Write the failing test**

Create `groups/gordon/scripts/targets.test.js`:

```javascript
import { test, expect } from "bun:test";
import { computeTargets } from "./targets.js";

test("computeTargets: Mifflin-St Jeor male recomp", () => {
  // BMR = 10*80 + 6.25*180 - 5*40 + 5 = 800 + 1125 - 200 + 5 = 1730
  // TDEE = 1730 * 1.55 = 2681.5 → 2682
  const t = computeTargets({ height_cm: 180, weight_kg: 80, age: 40, sex: "m", activity: 1.55, goal: "recomp" });
  expect(t.kcal).toBe(2682);
  expect(t.protein_g).toBe(160); // 2.0 * 80
  expect(t.fat_g).toBe(72); // 0.9 * 80
  // carbs = (2682 - 4*160 - 9*72) / 4 = (2682 - 640 - 648)/4 = 1394/4 = 348.5 → 349
  expect(t.carb_g).toBe(349);
  expect(t.provisional).toBe(1);
});

test("computeTargets: female uses -161 constant", () => {
  // BMR = 10*60 + 6.25*165 - 5*30 - 161 = 600 + 1031.25 - 150 - 161 = 1320.25
  // TDEE = 1320.25 * 1.2 = 1584.3 → 1584
  const t = computeTargets({ height_cm: 165, weight_kg: 60, age: 30, sex: "f", activity: 1.2, goal: "recomp" });
  expect(t.kcal).toBe(1584);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd groups/gordon && bun test scripts/targets.test.js`
Expected: FAIL — `Cannot find module "./targets.js"`.

- [ ] **Step 3: Implement `targets.js`**

Create `groups/gordon/scripts/targets.js`:

```javascript
import { openMealsDb, getProfile, setProfile, getTargets, setTargets } from "./db.js";

const MEALS_DB = "/workspace/agent/nutrition/meals.db";

// Recomp: calories ≈ maintenance (TDEE), protein 2.0 g/kg, fat 0.9 g/kg, carbs fill the rest.
export function computeTargets(p) {
  const sexConst = p.sex === "f" ? -161 : 5;
  const bmr = 10 * p.weight_kg + 6.25 * p.height_cm - 5 * p.age + sexConst;
  const tdee = bmr * (p.activity ?? 1.55);
  const kcal = Math.round(tdee);
  const protein_g = Math.round(2.0 * p.weight_kg);
  const fat_g = Math.round(0.9 * p.weight_kg);
  const carb_g = Math.max(0, Math.round((kcal - 4 * protein_g - 9 * fat_g) / 4));
  return {
    kcal, protein_g, fat_g, carb_g,
    basis: `mifflin x${p.activity ?? 1.55} (recomp)`,
    provisional: 1,
  };
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith("--")) {
      const key = argv[i].replace(/^--/, "");
      const next = argv[i + 1];
      if (next === undefined || next.startsWith("--")) out[key] = true;
      else { out[key] = next; i++; }
    }
  }
  return out;
}

if (import.meta.main) {
  const a = parseArgs(Bun.argv.slice(2));
  const db = openMealsDb(MEALS_DB);
  if (a.set) {
    const num = (v, d) => (v == null ? d : Number(v));
    const profile = {
      height_cm: num(a.height), weight_kg: num(a.weight), age: num(a.age, 40),
      sex: a.sex ?? "m", activity: num(a.activity, 1.55), goal: a.goal ?? "recomp",
    };
    setProfile(db, profile);
    const t = computeTargets(profile);
    setTargets(db, t);
    console.log(JSON.stringify({ profile, targets: t }));
  } else {
    const t = getTargets(db);
    if (t) { console.log(JSON.stringify(t)); }
    else {
      const p = getProfile(db);
      if (!p) { console.log(JSON.stringify({ error: "no profile — run intake (targets.js --set …)" })); }
      else { const nt = computeTargets(p); setTargets(db, nt); console.log(JSON.stringify(nt)); }
    }
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd groups/gordon && bun test scripts/targets.test.js`
Expected: PASS (2 tests).

- [ ] **Step 5: On-disk only** (gitignored).

---

## Task 3: daily-rollup.js

**Files:**
- Create: `groups/gordon/scripts/daily-rollup.js`
- Create: `groups/gordon/scripts/daily-rollup.test.js`

- [ ] **Step 1: Write the failing test**

Create `groups/gordon/scripts/daily-rollup.test.js`:

```javascript
import { test, expect } from "bun:test";
import { openMealsDb, insertMeal, setTargets } from "./db.js";
import { rollup } from "./daily-rollup.js";

test("rollup sums a day's meals and compares to targets", () => {
  const db = openMealsDb(":memory:");
  setTargets(db, { kcal: 2600, protein_g: 160, fat_g: 72, carb_g: 310, basis: "x", provisional: 1 });
  insertMeal(db, { ts: "2026-06-11T08:00:00.000Z", photo_ref: "a", kcal: 600, protein_g: 40, fat_g: 20, carb_g: 60, confidence: "med", note: "", items: [] });
  insertMeal(db, { ts: "2026-06-11T13:00:00.000Z", photo_ref: "b", kcal: 700, protein_g: 55, fat_g: 25, carb_g: 70, confidence: "med", note: "", items: [] });
  insertMeal(db, { ts: "2026-06-10T13:00:00.000Z", photo_ref: "c", kcal: 999, protein_g: 99, fat_g: 99, carb_g: 99, confidence: "med", note: "", items: [] }); // other day

  const r = rollup(db, "2026-06-11");
  expect(r.meals_n).toBe(2);
  expect(r.totals.kcal).toBe(1300);
  expect(r.totals.protein_g).toBe(95);
  expect(r.vs_target.kcal_pct).toBe(50); // 1300/2600
  expect(r.protein_hit).toBe(false); // 95 < 160*0.9
});

test("rollup with no targets returns totals and null vs_target", () => {
  const db = openMealsDb(":memory:");
  insertMeal(db, { ts: "2026-06-11T08:00:00.000Z", photo_ref: "a", kcal: 600, protein_g: 40, fat_g: 20, carb_g: 60, confidence: "med", note: "", items: [] });
  const r = rollup(db, "2026-06-11");
  expect(r.totals.kcal).toBe(600);
  expect(r.vs_target).toBeNull();
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd groups/gordon && bun test scripts/daily-rollup.test.js`
Expected: FAIL — `Cannot find module "./daily-rollup.js"`.

- [ ] **Step 3: Implement `daily-rollup.js`**

Create `groups/gordon/scripts/daily-rollup.js`:

```javascript
import { openMealsDb, getTargets } from "./db.js";

const MEALS_DB = "/workspace/agent/nutrition/meals.db";

export function rollup(db, date) {
  const rows = db.query("SELECT kcal, protein_g, fat_g, carb_g FROM meals WHERE substr(ts,1,10) = $date").all({ $date: date });
  const totals = { kcal: 0, protein_g: 0, fat_g: 0, carb_g: 0 };
  for (const r of rows) {
    totals.kcal += r.kcal; totals.protein_g += r.protein_g;
    totals.fat_g += r.fat_g; totals.carb_g += r.carb_g;
  }
  for (const k of Object.keys(totals)) totals[k] = Math.round(totals[k] * 10) / 10;

  const t = getTargets(db);
  let vs_target = null, protein_hit = null;
  if (t) {
    const pct = (a, b) => (b ? Math.round((a / b) * 100) : 0);
    vs_target = {
      kcal_pct: pct(totals.kcal, t.kcal), protein_pct: pct(totals.protein_g, t.protein_g),
      fat_pct: pct(totals.fat_g, t.fat_g), carb_pct: pct(totals.carb_g, t.carb_g),
      kcal_left: Math.round(t.kcal - totals.kcal), protein_left: Math.round(t.protein_g - totals.protein_g),
    };
    protein_hit = totals.protein_g >= t.protein_g * 0.9;
  }
  return { date, meals_n: rows.length, totals, targets: t, vs_target, protein_hit };
}

if (import.meta.main) {
  const args = Bun.argv.slice(2);
  let date = null;
  for (let i = 0; i < args.length; i++) if (args[i] === "--date") date = args[i + 1];
  if (!date) date = new Date().toISOString().slice(0, 10);
  const db = openMealsDb(MEALS_DB);
  console.log(JSON.stringify(rollup(db, date)));
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd groups/gordon && bun test scripts/daily-rollup.test.js`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the whole suite**

Run: `cd groups/gordon && bun test scripts/`
Expected: PASS — db (5) + lookup-food (5) + log-meal (1) + targets (2) + daily-rollup (2) = 15 tests.

- [ ] **Step 6: On-disk only** (gitignored).

---

## Task 4: intake skill

**Files:**
- Create: `groups/gordon/skills/intake/SKILL.md`

- [ ] **Step 1: Create `groups/gordon/skills/intake/SKILL.md`**

```markdown
---
name: intake
description: Use on first contact / when no targets exist, or when Сергей wants to (re)set body stats or goal. Triggers — "пересчитай таргеты", "мой вес X", first message with no profile, lookup-food/daily-rollup returning "no profile".
---

# intake — собрать профиль → посчитать таргеты

Нужны: рост (см), вес (кг), активность, цель. Возраст известен (40), пол — мужской. Не выпытывай всё разом — спроси недостающее коротко.

## Что спросить (если нет в профиле)
- **Рост** (см) — в `/workspace/global/about-sergei.md` его нет, спроси один раз.
- **Вес** (кг) — текущий. (В Фазе 4 поедет автоматом с умных весов через Грега; пока — спроси или возьми последний названный.)
- **Активность** — переведи в фактор: малоподвижный 1.2 / лёгкая 1.375 / умеренная (тренировки 3-5×/нед — твой случай с Payne) 1.55 / высокая 1.725. Предложи 1.55 по умолчанию (тренируешься с Пейном).
- **Цель** — рекомп (по умолчанию, из спека).

## Записать
```bash
bun /workspace/agent/scripts/targets.js --set --height <см> --weight <кг> --age 40 --sex m --activity 1.55 --goal recomp
```
Читай JSON `{profile, targets}`. Покажи Сергею таргеты простым языком, отметь что **провизорные** (на старте формула, дальше подстроятся по факту): «Цель на день: ~2680 ккал, белок 160, жир 72, углеводы ~350. Это стартовая прикидка — поправлю по тому, как пойдёт вес.»

## Когда «мой вес теперь X»
Пере-вызови `--set` с новым весом (остальное из профиля). Таргеты пересчитаются.
```

- [ ] **Step 2: On-disk only** (gitignored).

---

## Task 5: daily skill (evening summary)

**Files:**
- Create: `groups/gordon/skills/daily/SKILL.md`

- [ ] **Step 1: Create `groups/gordon/skills/daily/SKILL.md`**

```markdown
---
name: daily
description: Use for the evening nutrition summary (scheduled ~21:00 Makassar) or when Сергей asks "как по еде сегодня" / "сколько осталось". Reports the day vs targets in Ramsay's voice.
---

# daily — вечерний итог дня

```bash
bun /workspace/agent/scripts/daily-rollup.js
```
Читай JSON `{date, meals_n, totals, targets, vs_target, protein_hit}`. НЕ читай meals.db напрямую.

## Реакция (голос Рамзи, прямо Сергею, простой русский)
- Нет таргетов (`targets:null`) → запусти skill `intake` сначала.
- Есть → одна-две строки: сколько съел vs цель, добил ли белок, что осталось.
  - `protein_hit:false` + день кончается → дави на белок: «Белок 95 из 160. Куда это годится? Творог или протеин перед сном — и не спорь.»
  - В пределах нормы → коротко признай: «2510 из 2680, белок 158. Чисто. Так и держи.»
  - Перебор по калориям → «На 400 над целью. Завтра без вечерних добавок.»
- `vs_target.protein_left` / `kcal_left` — используй для «осталось» по запросу среди дня.

## Расписание
Если ещё не заведено — один раз создай вечерний таск (Makassar ~21:00):
`schedule_task` с `prompt`: «Загрузи skill daily и дай вечерний итог по еде», cron на 21:00 локального времени. Перед этим проверь `list_tasks` — не дублируй.
Тихие часы и бюджет проактива (3-4/день) — из INSTRUCTIONS, уважай.
```

- [ ] **Step 2: Update `groups/gordon/skills/index.md`**

Replace with:

```markdown
# Скилы Гордона — каталог

- `log-meal` — фото/текст еды → пайплайн identify→quantify→critique → запись в meals.db → реакция.
- `intake` — собрать рост/вес/активность/цель → посчитать рекомп-таргеты (`targets.js --set`).
- `daily` — вечерний итог дня vs таргеты, голос Рамзи; заводит расписание.

Появятся в следующих фазах:
- Фаза 4: `weekly` + командные контракты (Greg/Payne/Jarvis).
```

- [ ] **Step 3: On-disk only** (gitignored).

---

## Task 6: wire into CLAUDE.md

**Files:**
- Modify: `groups/gordon/CLAUDE.md`

- [ ] **Step 1: Replace the status banner**

Find:
```markdown
> **Статус:** логирование еды по фото работает (skill `log-meal`). Дневные итоги/таргеты и командные контракты (Greg/Payne/Jarvis) — следующие фазы.
```
Replace with:
```markdown
> **Статус:** логирование по фото (`log-meal`), рекомп-таргеты (`intake`/`targets.js`) и дневной итог (`daily`) работают. Командные контракты (Greg/Payne/Jarvis), body-comp и недельный вердикт — Фаза 4.
```

- [ ] **Step 2: Replace the §Скилы list**

Find:
```markdown
- `log-meal` — фото/текст еды → макросы → запись → реакция. Триггер: вложение-картинка, «залогируй», «что я съел».
```
Replace with:
```markdown
- `log-meal` — фото/текст еды → макросы → запись → реакция. Триггер: вложение-картинка, «залогируй», «что я съел».
- `intake` — собрать рост/вес/активность/цель → посчитать рекомп-таргеты. Триггер: нет профиля, «пересчитай таргеты», «мой вес X».
- `daily` — вечерний итог дня vs таргеты (расписание ~21:00 Makassar) или «как по еде сегодня».
```

- [ ] **Step 3: Add the targets/scripts to §Данные**

Find:
```markdown
- Скрипты (Bun, абсолютный путь): `scripts/lookup-food.js`, `scripts/log-meal.js`, модуль `scripts/db.js`. Креды USDA — `scripts/.env` (`USDA_FDC_API_KEY`).
```
Replace with:
```markdown
- Скрипты (Bun, абсолютный путь): `scripts/lookup-food.js`, `scripts/log-meal.js`, `scripts/targets.js` (профиль + рекомп-таргеты), `scripts/daily-rollup.js` (итог дня), модуль `scripts/db.js`. Креды USDA — `scripts/.env` (`USDA_FDC_API_KEY`).
- Профиль (рост/вес/возраст/активность/цель) и таргеты — в `meals.db` (таблицы `profile`/`targets`, по одной строке). Пишет/читает только `targets.js`.
```

- [ ] **Step 4: On-disk only** (gitignored).

---

## Task 7: deploy

**Files:** none (deploy). Same low-risk pattern as Phase 2 (additive files, no host restart; gordon's next session reads the new CLAUDE.md + mounts new scripts).

- [ ] **Step 1: scp + chown**

```bash
scp -r /Users/serg/git/nanoclaw/groups/gordon root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/ && \
ssh root@148.253.211.164 'chown -R nanoclaw:nanoclaw /home/nanoclaw/nanoclaw/groups/gordon'
```

- [ ] **Step 2: Verify files landed**

```bash
ssh root@148.253.211.164 'ls /home/nanoclaw/nanoclaw/groups/gordon/scripts/ /home/nanoclaw/nanoclaw/groups/gordon/skills/'
```
Expected: `targets.js`, `daily-rollup.js` (+ tests) in scripts; `intake/`, `daily/`, `log-meal/`, `index.md` in skills.

- [ ] **Step 3: Hand off (user smoke test)**

When Сергей next talks to Ramzi: intake captures height/weight → targets shown; after meals, "как по еде сегодня" → daily rollup. Verify the profile/targets row:
```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw/groups/gordon && bun -e \"const{openMealsDb,getProfile,getTargets}=await import(\\\"./scripts/db.js\\\");const db=openMealsDb(\\\"./nutrition/meals.db\\\");console.log(JSON.stringify({profile:getProfile(db),targets:getTargets(db)}))\""'
```

---

## Self-Review

**1. Spec coverage (Phase 3 scope):** targets (Task 2: Mifflin-St Jeor, protein 2.0/kg, fat 0.9/kg, carbs fill, provisional), daily rollup vs targets (Task 3), intake captures height/weight/activity (Task 4), evening summary direct to Сергей (Task 5). `nutrition_trend`→Jarvis + a2a explicitly deferred to Phase 4. ✓

**2. Placeholder scan:** all script/skill/CLAUDE.md content is full; every command concrete. ✓

**3. Type/name consistency:** `getProfile`/`setProfile`/`getTargets`/`setTargets`/`computeTargets`/`rollup` consistent across db.js, targets.js, daily-rollup.js, and their tests. Profile fields (`height_cm`/`weight_kg`/`age`/`sex`/`activity`/`goal`) and target fields (`kcal`/`protein_g`/`fat_g`/`carb_g`/`basis`/`provisional`) identical everywhere. `meals.ts` date filter uses `substr(ts,1,10)` matching the ISO `ts` written by Phase-2 `insertMeal`. ✓

**4. Math check:** BMR male 80kg/180cm/40 = 1730; ×1.55 = 2682; protein 160; fat 72; carbs 349 — verified in the test with explicit arithmetic. Female constant −161 verified. ✓

---

## Execution Handoff

Same as Phase 2: subagent-driven (recommended) or inline. Proceeding subagent-driven unless told otherwise.
