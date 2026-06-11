# Gordon Agent — Phase 2 (Logging Pipeline) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Snap a meal photo → Gordon estimates calories + macros (grounded against USDA FoodData Central / Open Food Facts via a subagent pipeline) → persists to `meals.db` → reacts in Ramsay's voice.

**Architecture:** Deterministic Bun scripts (token-economy: they own `meals.db`, return small JSON) + an LLM subagent chain orchestrated by the `log-meal` skill: **identify** (vision Task subagent → foods + grams) → **quantify** (`lookup-food.js` per item → per-100g macros × grams) → **critique** (adversarial Task subagent → fix hidden fats/portions, set confidence) → `log-meal.js` (persist) → Gordon's reply. Mirrors Scrooge's script/ledger pattern exactly.

**Tech Stack:** Bun (container runtime), `bun:sqlite`, `bun:test`, Bun `fetch`. No external npm deps (fetch + sqlite are built in).

**Spec:** [docs/superpowers/specs/2026-06-11-gordon-nutrition-agent-design.md](../specs/2026-06-11-gordon-nutrition-agent-design.md) · **Prereq:** Phase 1 deployed (gordon agent exists). USDA key already in `groups/gordon/scripts/.env` (`USDA_FDC_API_KEY`), verified working.

---

## Scope note

Phase 2 = the logging core only: photo → macros → stored → reaction. **Out of scope** (Phase 3): targets/TDEE, `daily-rollup.js`, `nutrition_trend` to Jarvis, the `intake`/`daily` skills. **Out of scope** (Phase 4): body-comp, Greg extension, a2a contracts. Don't build them here.

All agent files live under `groups/gordon/` (gitignored — deployed via scp, like Phase 1). The `.test.js` files run on the VDS / locally via Bun; they are NOT host vitest and are excluded from the host suite.

## File Structure

| File | Create | Responsibility |
|------|--------|----------------|
| `groups/gordon/scripts/_env.js` | Create (copy from scrooge) | Load `scripts/.env` into `process.env` regardless of cwd |
| `groups/gordon/scripts/db.js` | Create | `openMealsDb(path)` + schema (`meals`, `meal_items`) + `insertMeal(db, meal)` |
| `groups/gordon/scripts/db.test.js` | Create | Schema + insert + idempotency tests |
| `groups/gordon/scripts/lookup-food.js` | Create | USDA FDC + Open Food Facts → per-100g macros, cached; injectable fetch |
| `groups/gordon/scripts/lookup-food.test.js` | Create | Nutrient extraction + fallback + cache tests (stubbed fetch) |
| `groups/gordon/scripts/log-meal.js` | Create | Persist a critiqued meal (items + totals) to `meals.db` |
| `groups/gordon/scripts/log-meal.test.js` | Create | Persist + read-back test |
| `groups/gordon/skills/log-meal/SKILL.md` | Create | The identify→quantify→critique subagent pipeline + Ramsay reaction |
| `groups/gordon/skills/index.md` | Modify | List the `log-meal` skill |
| `groups/gordon/CLAUDE.md` | Modify | Wire the skill, data paths, token-economy; drop the "pипeline lands later" note |

Run all Bun tests with: `cd groups/gordon && bun test scripts/` (from a machine with Bun; the container has Bun, your Mac may need `brew install bun`).

---

## Task 1: env loader

**Files:**
- Create: `groups/gordon/scripts/_env.js`

- [ ] **Step 1: Copy scrooge's `_env.js` verbatim**

It resolves `.env` off `import.meta.url` (Bun's autoload walks from cwd, not the script dir — so `scripts/.env` is invisible otherwise). Create `groups/gordon/scripts/_env.js` with exactly this content:

```javascript
/**
 * Deterministic .env loader for Gordon's Bun scripts. Bun autoloads .env from
 * cwd, not the script dir, so scripts/.env is invisible when the agent invokes
 * scripts by absolute path from /workspace/agent/. Import this BEFORE reading
 * any env var; it loads the neighbour .env via import.meta.url. Fallback only —
 * never overrides values already in process.env.
 */
import { readFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const scriptDir = dirname(fileURLToPath(import.meta.url));

try {
  const text = readFileSync(join(scriptDir, ".env"), "utf8");
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq < 1) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (!(key in process.env)) process.env[key] = value;
  }
} catch (err) {
  if (err && err.code !== "ENOENT") {
    console.error(`_env.js: failed to read ${join(scriptDir, ".env")}: ${err.message}`);
  }
}
```

- [ ] **Step 2: Commit** (group files are gitignored, so this is a no-op for git — track on disk only)

This and every later task's "commit" applies only to non-gitignored files. `groups/gordon/**` is gitignored; verify with `git check-ignore groups/gordon/scripts/_env.js` (should print the path). No git commit for group files — they deploy via scp in Task 8.

---

## Task 2: meals.db module

**Files:**
- Create: `groups/gordon/scripts/db.js`
- Create: `groups/gordon/scripts/db.test.js`

- [ ] **Step 1: Write the failing test**

Create `groups/gordon/scripts/db.test.js`:

```javascript
import { test, expect } from "bun:test";
import { openMealsDb, insertMeal } from "./db.js";

function freshDb() {
  return openMealsDb(":memory:");
}

test("openMealsDb creates meals and meal_items tables", () => {
  const db = openMealsDb(":memory:");
  const tables = db
    .query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    .all()
    .map((r) => r.name);
  expect(tables).toContain("meals");
  expect(tables).toContain("meal_items");
});

test("insertMeal stores totals and items, returns id", () => {
  const db = freshDb();
  const id = insertMeal(db, {
    ts: "2026-06-11T08:00:00.000Z",
    photo_ref: "/workspace/inbox/m-1/plate.jpg",
    kcal: 620, protein_g: 48, fat_g: 22, carb_g: 55,
    confidence: "med",
    note: "grilled chicken, rice, no veg",
    items: [
      { food: "chicken breast", grams: 200, kcal: 330, protein_g: 62, fat_g: 7, carb_g: 0, source: "usda", fdc_id: "171077" },
      { food: "white rice", grams: 150, kcal: 290, protein_g: 6, fat_g: 1, carb_g: 64, source: "usda", fdc_id: "169756" },
    ],
  });
  expect(typeof id).toBe("string");
  const meal = db.query("SELECT * FROM meals WHERE id = $id").get({ $id: id });
  expect(meal.kcal).toBe(620);
  expect(meal.protein_g).toBe(48);
  const items = db.query("SELECT * FROM meal_items WHERE meal_id = $id ORDER BY food").all({ $id: id });
  expect(items.length).toBe(2);
  expect(items[0].food).toBe("chicken breast");
});

test("insertMeal is idempotent on the same ts+photo_ref", () => {
  const db = freshDb();
  const meal = { ts: "2026-06-11T08:00:00.000Z", photo_ref: "/workspace/inbox/m-1/plate.jpg", kcal: 100, protein_g: 10, fat_g: 1, carb_g: 5, confidence: "low", note: "", items: [] };
  const id1 = insertMeal(db, meal);
  const id2 = insertMeal(db, meal);
  expect(id1).toBe(id2);
  expect(db.query("SELECT COUNT(*) AS n FROM meals").get().n).toBe(1);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd groups/gordon && bun test scripts/db.test.js`
Expected: FAIL — `Cannot find module "./db.js"`.

- [ ] **Step 3: Implement `db.js`**

Create `groups/gordon/scripts/db.js` (mirrors scrooge's `ledger.js`: `bun:sqlite`, WAL, `$param` binds, sha256 id for idempotency):

```javascript
import { Database } from "bun:sqlite";
import { createHash } from "node:crypto";

export function openMealsDb(path) {
  const db = new Database(path);
  db.exec("PRAGMA journal_mode = WAL;"); // container-only file → no cross-mount concern
  initSchema(db);
  return db;
}

export function initSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS meals (
      id TEXT PRIMARY KEY, ts TEXT NOT NULL, photo_ref TEXT,
      kcal REAL NOT NULL, protein_g REAL NOT NULL, fat_g REAL NOT NULL, carb_g REAL NOT NULL,
      confidence TEXT, note TEXT, created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS meal_items (
      meal_id TEXT NOT NULL, food TEXT NOT NULL, grams REAL,
      kcal REAL, protein_g REAL, fat_g REAL, carb_g REAL, source TEXT, fdc_id TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_meals_ts ON meals(ts);
    CREATE INDEX IF NOT EXISTS idx_meal_items_meal ON meal_items(meal_id);
  `);
}

export function mealId(meal) {
  return createHash("sha256")
    .update([meal.ts, meal.photo_ref ?? ""].join("|"))
    .digest("hex")
    .slice(0, 16);
}

export function insertMeal(db, meal) {
  const id = meal.id ?? mealId(meal);
  const existing = db.query("SELECT id FROM meals WHERE id = $id").get({ $id: id });
  if (existing) return id;
  db.query(`
    INSERT INTO meals (id, ts, photo_ref, kcal, protein_g, fat_g, carb_g, confidence, note, created_at)
    VALUES ($id,$ts,$photo_ref,$kcal,$protein_g,$fat_g,$carb_g,$confidence,$note,$created_at)
  `).run({
    $id: id, $ts: meal.ts, $photo_ref: meal.photo_ref ?? null,
    $kcal: meal.kcal, $protein_g: meal.protein_g, $fat_g: meal.fat_g, $carb_g: meal.carb_g,
    $confidence: meal.confidence ?? null, $note: meal.note ?? null,
    $created_at: meal.created_at ?? new Date().toISOString(),
  });
  const insItem = db.query(`
    INSERT INTO meal_items (meal_id, food, grams, kcal, protein_g, fat_g, carb_g, source, fdc_id)
    VALUES ($meal_id,$food,$grams,$kcal,$protein_g,$fat_g,$carb_g,$source,$fdc_id)
  `);
  for (const it of meal.items ?? []) {
    insItem.run({
      $meal_id: id, $food: it.food, $grams: it.grams ?? null,
      $kcal: it.kcal ?? null, $protein_g: it.protein_g ?? null, $fat_g: it.fat_g ?? null,
      $carb_g: it.carb_g ?? null, $source: it.source ?? null, $fdc_id: it.fdc_id ?? null,
    });
  }
  return id;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd groups/gordon && bun test scripts/db.test.js`
Expected: PASS (3 tests).

- [ ] **Step 5: On-disk only** (gitignored — no git commit).

---

## Task 3: lookup-food.js (USDA + Open Food Facts)

**Files:**
- Create: `groups/gordon/scripts/lookup-food.js`
- Create: `groups/gordon/scripts/lookup-food.test.js`

`lookupFood(query, { fetchImpl, apiKey })` queries USDA FoodData Central search, extracts per-100g macros by nutrient number (208 energy/kcal, 203 protein, 204 fat, 205 carbs), and falls back to Open Food Facts if USDA returns nothing. `fetchImpl` is injectable so tests never hit the network.

- [ ] **Step 1: Write the failing test**

Create `groups/gordon/scripts/lookup-food.test.js`:

```javascript
import { test, expect } from "bun:test";
import { extractUsdaMacros, lookupFood } from "./lookup-food.js";

const USDA_HIT = {
  foods: [{
    description: "Chicken, breast, grilled",
    fdcId: 171077,
    foodNutrients: [
      { nutrientNumber: "208", value: 165 },
      { nutrientNumber: "203", value: 31 },
      { nutrientNumber: "204", value: 3.6 },
      { nutrientNumber: "205", value: 0 },
    ],
  }],
};

test("extractUsdaMacros pulls per-100g macros by nutrient number", () => {
  const m = extractUsdaMacros(USDA_HIT.foods[0]);
  expect(m.kcal_100g).toBe(165);
  expect(m.protein_100g).toBe(31);
  expect(m.fat_100g).toBe(3.6);
  expect(m.carb_100g).toBe(0);
});

test("extractUsdaMacros reads Foundation energy from 957 when 208 is absent", () => {
  const foundation = { foodNutrients: [
    { nutrientNumber: "203", value: 22.5 }, { nutrientNumber: "204", value: 1.93 },
    { nutrientNumber: "205", value: 0 }, { nutrientNumber: "957", value: 106 }, { nutrientNumber: "958", value: 112 },
  ]};
  const m = extractUsdaMacros(foundation);
  expect(m.kcal_100g).toBe(106); // 957 preferred over 958
  expect(m.protein_100g).toBe(22.5);
});

test("lookupFood returns USDA result with source usda", async () => {
  const fetchImpl = async () => ({ ok: true, json: async () => USDA_HIT });
  const res = await lookupFood("chicken breast", { fetchImpl, apiKey: "k", cache: new Map() });
  expect(res.source).toBe("usda");
  expect(res.fdc_id).toBe("171077");
  expect(res.protein_100g).toBe(31);
});

test("lookupFood falls back to Open Food Facts when USDA is empty", async () => {
  const offHit = { products: [{ product_name: "Tofu", nutriments: { "energy-kcal_100g": 144, proteins_100g: 17, fat_100g: 9, carbohydrates_100g: 2 } }] };
  let call = 0;
  const fetchImpl = async () => {
    call++;
    if (call === 1) return { ok: true, json: async () => ({ foods: [] }) }; // USDA empty
    return { ok: true, json: async () => offHit }; // OFF
  };
  const res = await lookupFood("tofu", { fetchImpl, apiKey: "k", cache: new Map() });
  expect(res.source).toBe("off");
  expect(res.kcal_100g).toBe(144);
  expect(res.protein_100g).toBe(17);
});

test("lookupFood serves from cache without a second fetch", async () => {
  const cache = new Map();
  let calls = 0;
  const fetchImpl = async () => { calls++; return { ok: true, json: async () => USDA_HIT }; };
  await lookupFood("chicken breast", { fetchImpl, apiKey: "k", cache });
  await lookupFood("chicken breast", { fetchImpl, apiKey: "k", cache });
  expect(calls).toBe(1);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd groups/gordon && bun test scripts/lookup-food.test.js`
Expected: FAIL — `Cannot find module "./lookup-food.js"`.

- [ ] **Step 3: Implement `lookup-food.js`**

Create `groups/gordon/scripts/lookup-food.js`:

```javascript
import "./_env.js";
import { readFileSync, writeFileSync } from "fs";

const USDA_URL = "https://api.nal.usda.gov/fdc/v1/foods/search";
const OFF_URL = "https://world.openfoodfacts.org/cgi/search.pl";
const CACHE_PATH = "/workspace/agent/nutrition/food-cache.json";

// Energy varies by dataType: Branded / SR Legacy use 208; Foundation foods omit
// 208 and report energy under 957 (Atwater General) / 958 (Atwater Specific).
const ENERGY_NUMS = ["208", "957", "958"];
const NUTRIENT = { protein_100g: "203", fat_100g: "204", carb_100g: "205" };

export function extractUsdaMacros(food) {
  const byNum = {};
  for (const n of food.foodNutrients ?? []) {
    const num = String(n.nutrientNumber ?? n.number ?? n.nutrient?.number ?? "");
    if (num && byNum[num] == null) byNum[num] = n.value ?? n.amount ?? 0;
  }
  const kcal = ENERGY_NUMS.map((n) => byNum[n]).find((v) => v != null) ?? 0;
  return {
    kcal_100g: Number(kcal),
    protein_100g: Number(byNum[NUTRIENT.protein_100g] ?? 0),
    fat_100g: Number(byNum[NUTRIENT.fat_100g] ?? 0),
    carb_100g: Number(byNum[NUTRIENT.carb_100g] ?? 0),
  };
}

async function queryUsda(query, fetchImpl, apiKey) {
  const url = `${USDA_URL}?query=${encodeURIComponent(query)}&pageSize=1&api_key=${apiKey}`;
  const r = await fetchImpl(url);
  if (!r.ok) return null;
  const data = await r.json();
  const food = data.foods?.[0];
  if (!food) return null;
  return { name: food.description, source: "usda", fdc_id: String(food.fdcId ?? ""), ...extractUsdaMacros(food) };
}

async function queryOff(query, fetchImpl) {
  const url = `${OFF_URL}?search_terms=${encodeURIComponent(query)}&search_simple=1&action=process&json=1&page_size=1`;
  const r = await fetchImpl(url);
  if (!r.ok) return null;
  const data = await r.json();
  const p = data.products?.[0];
  if (!p) return null;
  const n = p.nutriments ?? {};
  return {
    name: p.product_name || query, source: "off", fdc_id: "",
    kcal_100g: Number(n["energy-kcal_100g"] ?? 0),
    protein_100g: Number(n.proteins_100g ?? 0),
    fat_100g: Number(n.fat_100g ?? 0),
    carb_100g: Number(n.carbohydrates_100g ?? 0),
  };
}

export async function lookupFood(query, opts = {}) {
  const fetchImpl = opts.fetchImpl ?? fetch;
  const apiKey = opts.apiKey ?? process.env.USDA_FDC_API_KEY;
  const cache = opts.cache ?? new Map();
  const key = query.toLowerCase().trim();
  if (cache.has(key)) return cache.get(key);
  let res = await queryUsda(query, fetchImpl, apiKey);
  if (!res || (res.kcal_100g === 0 && res.protein_100g === 0)) {
    const off = await queryOff(query, fetchImpl);
    if (off) res = off;
  }
  if (!res) res = { name: query, source: "estimate", fdc_id: "", kcal_100g: 0, protein_100g: 0, fat_100g: 0, carb_100g: 0 };
  cache.set(key, res);
  return res;
}

function loadFileCache() {
  try { return new Map(Object.entries(JSON.parse(readFileSync(CACHE_PATH, "utf8")))); }
  catch { return new Map(); }
}
function saveFileCache(cache) {
  try { writeFileSync(CACHE_PATH, JSON.stringify(Object.fromEntries(cache))); } catch {}
}

if (import.meta.main) {
  const query = Bun.argv.slice(2).join(" ").replace(/^--query\s*/, "").trim();
  if (!process.env.USDA_FDC_API_KEY) {
    console.log(JSON.stringify({ error: "no USDA_FDC_API_KEY in scripts/.env" }));
    process.exit(0);
  }
  const cache = loadFileCache();
  const res = await lookupFood(query, { cache });
  saveFileCache(cache);
  console.log(JSON.stringify(res));
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd groups/gordon && bun test scripts/lookup-food.test.js`
Expected: PASS (4 tests).

- [ ] **Step 5: On-disk only** (gitignored).

---

## Task 4: log-meal.js (persist a critiqued meal)

**Files:**
- Create: `groups/gordon/scripts/log-meal.js`
- Create: `groups/gordon/scripts/log-meal.test.js`

Takes a critiqued meal JSON (items already quantified + totals + confidence) and writes it via `insertMeal`. The agent passes the JSON on stdin (avoids huge argv); the script reads stdin, persists, prints `{meal_id, totals}`.

- [ ] **Step 1: Write the failing test**

Create `groups/gordon/scripts/log-meal.test.js`:

```javascript
import { test, expect } from "bun:test";
import { openMealsDb } from "./db.js";
import { logMeal } from "./log-meal.js";

test("logMeal persists a meal and returns id + totals", () => {
  const db = openMealsDb(":memory:");
  const out = logMeal(db, {
    ts: "2026-06-11T12:00:00.000Z",
    photo_ref: "/workspace/inbox/m-2/lunch.jpg",
    confidence: "high",
    note: "chicken + rice + salad",
    items: [
      { food: "chicken breast", grams: 200, kcal: 330, protein_g: 62, fat_g: 7, carb_g: 0, source: "usda", fdc_id: "171077" },
      { food: "white rice", grams: 150, kcal: 290, protein_g: 6, fat_g: 1, carb_g: 64, source: "usda", fdc_id: "169756" },
    ],
  });
  expect(out.meal_id).toBeString();
  expect(out.totals.kcal).toBe(620);
  expect(out.totals.protein_g).toBe(68);
  const n = db.query("SELECT COUNT(*) AS n FROM meal_items WHERE meal_id = $id").get({ $id: out.meal_id }).n;
  expect(n).toBe(2);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd groups/gordon && bun test scripts/log-meal.test.js`
Expected: FAIL — `Cannot find module "./log-meal.js"`.

- [ ] **Step 3: Implement `log-meal.js`**

Create `groups/gordon/scripts/log-meal.js`:

```javascript
import { openMealsDb, insertMeal } from "./db.js";

const MEALS_DB = "/workspace/agent/nutrition/meals.db";

function sumTotals(items) {
  const t = { kcal: 0, protein_g: 0, fat_g: 0, carb_g: 0 };
  for (const it of items ?? []) {
    t.kcal += Number(it.kcal ?? 0);
    t.protein_g += Number(it.protein_g ?? 0);
    t.fat_g += Number(it.fat_g ?? 0);
    t.carb_g += Number(it.carb_g ?? 0);
  }
  // round to 1 decimal to avoid float noise
  for (const k of Object.keys(t)) t[k] = Math.round(t[k] * 10) / 10;
  return t;
}

export function logMeal(db, meal) {
  const totals = sumTotals(meal.items);
  const id = insertMeal(db, { ...meal, ...totals });
  return { meal_id: id, totals };
}

if (import.meta.main) {
  const input = await Bun.stdin.text();
  let meal;
  try { meal = JSON.parse(input); }
  catch { console.log(JSON.stringify({ error: "invalid JSON on stdin" })); process.exit(0); }
  if (!meal.ts) meal.ts = new Date().toISOString();
  const db = openMealsDb(MEALS_DB);
  console.log(JSON.stringify(logMeal(db, meal)));
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd groups/gordon && bun test scripts/log-meal.test.js`
Expected: PASS (1 test).

- [ ] **Step 5: Run the whole script suite**

Run: `cd groups/gordon && bun test scripts/`
Expected: PASS — all tests across db / lookup-food / log-meal (8 total).

- [ ] **Step 6: On-disk only** (gitignored).

---

## Task 5: the `log-meal` skill (subagent pipeline)

**Files:**
- Create: `groups/gordon/skills/log-meal/SKILL.md`
- Modify: `groups/gordon/skills/index.md`

This is instruction (no unit test) — it tells Gordon how to run the pipeline. Validated by the Task 8 smoke test.

- [ ] **Step 1: Create `groups/gordon/skills/log-meal/SKILL.md`**

```markdown
---
name: log-meal
description: Use when Сергей sends a meal photo (or text describing food) and you must log it. Triggers — `[file: …jpg/png …]` attachment, "залогируй", "что я съел", a plate photo with/without caption.
---

# log-meal — фото еды → макросы → запись → реакция

Token-economy (жёстко): `meals.db` и `food-cache.json` в контекст НЕ читаются. Только скрипты их трогают. Картинку читает identify-субагент, не ты напрямую (экономия контекста).

## Пайплайн (ты оркестратор, шаги — субагенты + скрипты)

Дано: путь к фото из `[file: … saved to /workspace/inbox/<id>/<name>]` (+ подпись Сергея, если есть).

### 1. identify (Task-субагент, vision)
Делегируй `Task`:
```
Task({
  description: "identify foods on plate",
  prompt: "Прочитай изображение по пути <ABS_PATH> через Read (vision). Верни СТРОГО JSON-массив блюд с оценкой граммовки, без пояснений: [{\"food\":\"<en название для поиска в базе>\",\"est_grams\":<число>,\"prep\":\"<grilled|fried|raw|boiled|...>\"}]. Учитывай подпись пользователя как приоритет по порциям: <CAPTION или 'нет'>. Если на фото несколько порций — раздели. Масло/соус/заправку, если видны или вероятны, добавь отдельной позицией."
})
```
Распарси JSON-ответ в массив `items`.

### 2. quantify (скрипт на каждую позицию)
Для каждого `item` вызови:
```bash
bun /workspace/agent/scripts/lookup-food.js --query "<item.food>"
```
Читай ТОЛЬКО JSON-выхлоп `{name,kcal_100g,protein_100g,fat_100g,carb_100g,source,fdc_id}`. Посчитай макросы позиции: `kcal = kcal_100g * est_grams / 100` (так же protein/fat/carb). Собери `items[]` с полями `{food,grams,kcal,protein_g,fat_g,carb_g,source,fdc_id}` (округли до 1 знака).

### 3. critique (Task-субагент, adversarial)
Делегируй `Task` с собранным черновиком:
```
Task({
  description: "critique meal estimate",
  prompt: "Вот черновик оценки приёма пищи: <DRAFT_JSON>. Ты придирчивый ревизор. Проверь: (а) не забыто ли масло/соус/заправка/напиток (скрытые калории), (б) реалистична ли граммовка по фото, (в) сходится ли сумма kcal с 4*P+9*F+4*C (±15%). Верни СТРОГО JSON: {\"items\":[...исправленный...],\"confidence\":\"high|med|low\",\"note\":\"<1 строка что поправил>\"}. Если всё ок — верни те же items с confidence."
})
```
Используй исправленные `items` + `confidence` + `note`.

### 4. persist (скрипт, JSON на stdin)
```bash
echo '<{ts,photo_ref,confidence,note,items}>' | bun /workspace/agent/scripts/log-meal.js
```
`ts` = сейчас (ISO), `photo_ref` = путь фото. Читай выхлоп `{meal_id, totals}`.

### 5. реакция (ты, голос Рамзи)
Одна-две строки Сергею по `totals` + `confidence`. Огонь по делу, не по личности. Примеры тона:
- «Курица, рис, ноль овощей. 620 ккал, 48 белка. Вторая бежевая тарелка за день. Где цвет?»
- «Прилично. 540 ккал, 52 белка, овощи на месте. Так и держи.»
- Низкая `confidence` → коротко уточни: «Соус был? Накинул ~150 ккал на глаз — скажи если нет.»

Простой русский, аббревиатуры разворачивай (см. CLAUDE.md). Не вываливай таблицы и пер-позиционные числа, если не просят — итог + вердикт.

## Текст без фото
«Съел 3 яйца и овсянку» — пропусти шаг 1 (identify), сам собери `items` из текста, дальше шаги 2-5 как есть.

## Сбои
- identify вернул не-JSON → переспроси субагента один раз; не вышло — попроси Сергея описать словами.
- `lookup-food.js` отдал `{"error":"no USDA_FDC_API_KEY…"}` → скажи Сергею: ключ USDA не подгрузился, проверь `scripts/.env`. Open Food Facts работает без ключа, но точность ниже.
- `lookup-food.js` `source:"estimate"` (база не нашла) → позиция без заземления; пометь это в реакции («рис на глаз — в базе не нашёл»).
```

- [ ] **Step 2: Update `groups/gordon/skills/index.md`**

Replace the file with:

```markdown
# Скилы Гордона — каталог

- `log-meal` — Сергей прислал фото/текст еды → пайплайн identify→quantify→critique → запись в meals.db → реакция Рамзи.

Появятся в следующих фазах:
- Фаза 3: `intake`, `daily`, `targets`.
- Фаза 4: `weekly`.
```

- [ ] **Step 3: On-disk only** (gitignored).

---

## Task 6: wire the skill into Gordon's CLAUDE.md

**Files:**
- Modify: `groups/gordon/CLAUDE.md`

- [ ] **Step 1: Replace the status banner**

Find:
```markdown
> **Статус:** это фундамент. Логирование еды по фото, оценка макросов по базам (USDA / Open Food Facts), дневные итоги и командные контракты подключаются в следующих фазах. Пока — знакомство, персона и прямой разговор.
```
Replace with:
```markdown
> **Статус:** логирование еды по фото работает (skill `log-meal`). Дневные итоги/таргеты и командные контракты (Greg/Payne/Jarvis) — следующие фазы.
```

- [ ] **Step 2: Replace the §Скилы section**

Find:
```markdown
## Скилы

См. `skills/index.md` — каталог. Грузишь через `Skill` tool по необходимости. Пока пусто: процедурные скилы (логирование, таргеты, дневной/недельный цикл) добавляются в Фазах 2–4.
```
Replace with:
```markdown
## Скилы

См. `skills/index.md` — каталог. Грузишь через `Skill` tool по необходимости.

- `log-meal` — фото/текст еды → макросы → запись → реакция. Триггер: вложение-картинка, «залогируй», «что я съел».

## Данные (token-economy, жёстко)

- `/workspace/agent/nutrition/meals.db` — приёмы пищи (totals + позиции). Пишут/читают ТОЛЬКО скрипты.
- `/workspace/agent/nutrition/food-cache.json` — кэш макросов продуктов.
- **Никогда** не `cat`/Read для `meals.db` / `food-cache.json` / картинок еды в свой контекст. Картинку читает identify-субагент; базы — скрипты; ты получаешь маленький JSON. Нарушение раздувает контекст.
- Скрипты (Bun, абсолютный путь): `scripts/lookup-food.js`, `scripts/log-meal.js`, модуль `scripts/db.js`. Креды USDA — `scripts/.env` (`USDA_FDC_API_KEY`).
```

- [ ] **Step 3: On-disk only** (gitignored).

---

## Task 7: deploy scripts + skill to the VDS

**Files:** none (deploy).

The Phase-2 files are all under `groups/gordon/` (gitignored). Deploy by re-scp'ing the group folder, then restart so Gordon's session picks up the new CLAUDE.md (instruction changes need a fresh session — see memory `feedback_agent_instruction_reload`; scripts are live-mounted but CLAUDE.md is read at session birth).

- [ ] **Step 1: Copy the updated group folder to the VDS**

```bash
scp -r /Users/serg/git/nanoclaw/groups/gordon root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/ && \
ssh root@148.253.211.164 'chown -R nanoclaw:nanoclaw /home/nanoclaw/nanoclaw/groups/gordon'
```

- [ ] **Step 2: Verify Bun deps + tests on the VDS** (the container has Bun; run the suite there to confirm parity)

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw/groups/gordon && bun test scripts/ 2>&1 | tail -10"'
```
Expected: 8 tests pass. (If `bun` isn't on PATH for the nanoclaw shell, the scripts still run inside the agent container which has Bun — this step is a host-side sanity check only; skip if Bun isn't installed on the host and rely on the smoke test.)

- [ ] **Step 3: Restart Gordon's session so the new CLAUDE.md loads**

Instruction changes are ignored by a live SDK session (it resumes via `continuation:claude`). Force a fresh session for gordon:

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw && ./bin/ncl groups restart --id gordon 2>&1 | tail -3"'
```
If `ncl groups restart` reports `restarted:0` (no live container yet — gordon hasn't been messaged since Phase 1), that's fine: the next user message spawns a fresh container that reads the new CLAUDE.md. If a continuation row exists and blocks the reload, see memory `feedback_agent_instruction_reload` (kill container + DELETE continuation row).

---

## Task 8: end-to-end smoke test

**Files:** none (manual verification).

- [ ] **Step 1: Send Gordon a real meal photo**

From the iOS app (after the Phase-1 iOS rebuild so «Ramzi» is selectable), pick Ramzi and send a photo of a plate with an optional caption. Or, to test before the iOS rebuild, send via any wired channel that reaches gordon.

- [ ] **Step 2: Confirm the pipeline ran**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw && ./bin/ncl sessions list | grep gordon; echo === meals ===; ls -la groups/gordon/nutrition/ 2>/dev/null"'
```
Then inspect the logged meal (via a throwaway query — never read meals.db into agent context):
```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw/groups/gordon && bun -e \"const{openMealsDb}=await import(\\\"./scripts/db.js\\\");const db=openMealsDb(\\\"./nutrition/meals.db\\\");console.log(JSON.stringify(db.query(\\\"SELECT id,ts,kcal,protein_g,confidence FROM meals ORDER BY ts DESC LIMIT 3\\\").all()))\""'
```
Expected: a row with plausible kcal/protein and a `confidence`. Gordon replied in-character in the app.

- [ ] **Step 3: Check container logs if the reply didn't arrive**

Container logs are lost on exit (`--rm`), so check the outbound DB and host log:
```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw && tail -30 logs/nanoclaw.error.log | grep -iE \"gordon|error\" | tail -10"'
```
Common failures: `lookup-food.js` USDA key not loaded (check `scripts/.env` deployed), identify subagent returned non-JSON (the skill retries once), or `<message to=\"Unknown\">` drop (Phase-1 channel destination missing — but it was verified deployed).

---

## Self-Review

**1. Spec coverage (Phase 2 scope):** photo→macros pipeline (Tasks 3,5), food-DB grounding USDA+OFF (Task 3), subagent chain identify→quantify→critique (Task 5), `meals.db` storage + token-economy (Tasks 2,4,6), Ramsay reaction (Task 5 step 5). Targets/rollups/a2a/body-comp explicitly deferred — not present. ✓

**2. Placeholder scan:** every script + SKILL.md + CLAUDE.md edit has full content; every command is concrete. No "TBD"/"add error handling". ✓

**3. Type/name consistency:** `openMealsDb`/`insertMeal`/`mealId` (db.js) used identically in db.test.js, log-meal.js, log-meal.test.js, and the smoke-test query. `lookupFood`/`extractUsdaMacros` match between lookup-food.js and its test. Per-100g field names (`kcal_100g`/`protein_100g`/`fat_100g`/`carb_100g`) consistent across lookup-food.js, its test, and the SKILL.md quantify step. Item field names (`food`/`grams`/`kcal`/`protein_g`/`fat_g`/`carb_g`/`source`/`fdc_id`) consistent across db.js, log-meal.js, tests, and SKILL.md. ✓

**4. USDA energy extraction — verified live + fixed:** a live FDC call revealed Foundation foods omit nutrient 208 and report energy under 957 (Atwater General) / 958, so `extractUsdaMacros` now tries 208 → 957 → 958 (regression-tested). Protein/fat/carb (203/204/205) are consistent. Per-100g assumption holds for Foundation/SR Legacy; Branded items occasionally report per-serving — the `critique` subagent + smoke test catch any gross outlier.

---

## Execution Handoff

Plan complete. Two execution options:
1. **Subagent-Driven (recommended)** — fresh subagent per task, review between, fast iteration.
2. **Inline Execution** — execute here with checkpoints.

Which approach?
