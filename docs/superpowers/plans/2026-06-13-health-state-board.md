# Health Data Integrity, SQLite Storage & State Board — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix understated sleep metrics, replace the duplicate-bloated `raw.jsonl` with a deduped per-agent SQLite store, and add an in-app "Состояние" board (4 health rings + all-agent summaries).

**Architecture:** Three phases on one data path. **P1 (C)** widens the iOS HealthKit query window so pre-midnight sleep isn't dropped. **P2 (B)** moves health ingestion to `groups/<folder>/health/health.db` (upsert by date); host writes via `better-sqlite3`, Greg's `analyze.js` reads via `bun:sqlite`. **P3/P4 (A)** add `levels` (energy/stress) to `analyze.js`, a `GET /ios/state` endpoint that serves parsed `profiles/*.md`, and the iOS strip + board UI.

**Tech Stack:** Swift/HealthKit (iOS), Node + `better-sqlite3` + vitest (host), Bun + `bun:sqlite` + `bun:test` (container `analyze.js`).

**Spec:** `docs/superpowers/specs/2026-06-13-health-state-board-design.md`

**Commit convention:** every commit carries the repo trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

**Test commands per area:**
- Host (vitest): `pnpm exec vitest run <path>`
- `analyze.js` (Bun): `cd groups/greg/scripts && bun test` — requires `bun`. On a host without bun, run inside a throwaway agent container (see `CLAUDE.md` → "host без bun").
- iOS: `cd ios/JarvisApp && xcodegen generate` after adding files, then `xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:<TestTarget/Class/method>` (or XcodeBuildMCP `test_sim`).

---

## Phase P1 — C: Sleep query window fix (iOS)

**Root cause (proven):** `HealthHistory.fetch(from:to:)` queries overnight metrics from `start = startOfDay(fromDay)`. Sleep/HRV/SpO₂ samples lying entirely before midnight of the window's left-edge day are excluded, understating `deepMin` (e.g. 28 vs ~58). Fix: query overnight metrics from one day earlier, keep wake-day bucketing, drop out-of-range days before emit.

### Task 1: `overnightWindowStart` helper + reducer guard

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift` (add static helper after `reduceSpo2`, ~line 54)
- Test: `ios/JarvisApp/Sources/JarvisAppTests/HealthHistoryTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `HealthHistoryTests`:

```swift
func testOvernightWindowStartIsOneDayBefore() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Makassar")!
    let from = cal.date(from: DateComponents(year: 2026, month: 6, day: 13))!
    let got = HealthHistory.overnightWindowStart(from: from, calendar: cal)
    let want = cal.date(from: DateComponents(year: 2026, month: 6, day: 12))!
    XCTAssertEqual(got, want)
}

func testBucketSleepStagesCountsPreMidnightDeep() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Makassar")!
    let dayStart = cal.date(from: DateComponents(year: 2026, month: 6, day: 13))!
    func at(_ h: Int, _ m: Int, _ off: Int) -> Date {
        cal.date(byAdding: .day, value: off,
                 to: cal.date(bySettingHour: h, minute: m, second: 0, of: dayStart)!)!
    }
    let samples = [
        HealthHistory.SleepSampleInput(stage: 4, start: at(22, 50, -1), end: at(23, 30, -1)), // 40m deep, pre-midnight
        HealthHistory.SleepSampleInput(stage: 4, start: at(2, 0, 0),  end: at(2, 40, 0)),      // 40m deep, post-midnight
    ]
    let r = HealthHistory.bucketSleepStages(samples, dayStart: dayStart)
    XCTAssertEqual(r.deepMin, 80)
}
```

- [ ] **Step 2: Run — expect FAIL**

Run: `xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/HealthHistoryTests/testOvernightWindowStartIsOneDayBefore`
Expected: FAIL — `overnightWindowStart` not found.

- [ ] **Step 3: Implement the helper**

In `HealthHistory.swift`, after `reduceSpo2(...)` (line 54), inside `enum HealthHistory`:

```swift
    /// Overnight metrics (sleep stages, morning HRV, nocturnal SpO₂) can begin
    /// before midnight of the wake day. The fetch window must start one day
    /// before the requested `from` so the left-edge day's pre-midnight samples
    /// are included; wake-day bucketing keeps attribution correct.
    static func overnightWindowStart(from start: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -1, to: start)!
    }
```

- [ ] **Step 4: Run — expect PASS** (both new tests)

Run: `xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/HealthHistoryTests/testOvernightWindowStartIsOneDayBefore -only-testing:JarvisAppTests/HealthHistoryTests/testBucketSleepStagesCountsPreMidnightDeep`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift ios/JarvisApp/Sources/JarvisAppTests/HealthHistoryTests.swift
git commit -m "fix(ios): add overnight window-start helper for sleep fetch"
```

### Task 2: Wire overnight queries to the widened window + range-filter emit

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift` (`fetch(from:to:)`: lines 96, 171-208, 210-212, 370-373)

- [ ] **Step 1: Compute `sleepStart` once**

After `let start = cal.startOfDay(for: fromDay)` (line 96) and the `end` guard, add:

```swift
        // Overnight metrics need the previous evening; widen their left edge.
        let sleepStart = HealthHistory.overnightWindowStart(from: start, calendar: cal)
```

- [ ] **Step 2: Use `sleepStart` in the three overnight queries**

Change `withStart: start` → `withStart: sleepStart` in exactly these three predicates:
- Morning-HRV query `hrvQ` (line ~173): `predicate: HKQuery.predicateForSamples(withStart: sleepStart, end: end),`
- SpO₂ query `spo2Q` (line ~191): `predicate: HKQuery.predicateForSamples(withStart: sleepStart, end: end),`
- Sleep call (line ~212): `sleepSamplesByWakeDay(start: sleepStart, end: end, bucket: bucketKey) { byWakeDay in`

Leave all `collection(...)` calls and the workout query on `start` (daily metrics bucket by start-day; no change).

- [ ] **Step 3: Drop out-of-range days before completion**

Replace the `group.notify` block (lines 370-373):

```swift
        group.notify(queue: .main) {
            // The widened sleep window can surface a partial (from-1) wake-day row;
            // emit only days within the requested [from, to] range.
            let rows = byDay.values
                .filter { $0.date >= from && $0.date <= to }
                .sorted { $0.date < $1.date }
            completion(Array(rows))
        }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild build -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: BUILD SUCCEEDED. (Window behavior itself needs HealthKit; verified on-device by re-fetching a day with early sleep and confirming `deepMin` ≈ Health app.)

- [ ] **Step 5: Run the full HealthHistory test class**

Run: `xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/HealthHistoryTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift
git commit -m "fix(ios): widen overnight fetch window so pre-midnight sleep counts"
```

---

## Phase P2 — B: `raw.jsonl` → per-agent SQLite (dedup)

**Why:** `raw.jsonl` is 99.7% duplicate rows (every refresh re-appends a window of days). Move to `health.db` (`health_days`, PK = `date`, upsert). Host writes (`better-sqlite3`); container `analyze.js` reads (`bun:sqlite`). `journal_mode=DELETE` for bind-mount visibility (same rule as session DBs — see `container/agent-runner/src/db/connection.ts`).

### Task 3: `health-db.ts` — schema, upsert, read

**Files:**
- Create: `src/channels/ios-app/v2/health-db.ts`
- Test: `src/channels/ios-app/v2/health-db.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from 'vitest';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openHealthDb, upsertHealthDays, readHealthDays } from './health-db.js';
import type { HealthUploadDay } from '../../../../shared/ios-app-protocol/index.js';

function day(date: string, deepMin: number): HealthUploadDay {
  return { date, deepMin, sleepHours: 7 } as HealthUploadDay;
}

describe('health-db', () => {
  it('upserts by date — last write wins, no duplicate rows', () => {
    const dir = mkdtempSync(join(tmpdir(), 'hdb-'));
    const db = openHealthDb(join(dir, 'health.db'));
    upsertHealthDays(db, [day('2026-06-13', 28), day('2026-06-12', 49)]);
    upsertHealthDays(db, [day('2026-06-13', 58)]); // corrected re-upload
    const rows = readHealthDays(db);
    expect(rows.map((r) => r.date)).toEqual(['2026-06-12', '2026-06-13']); // 2 rows, not 3
    expect(rows.find((r) => r.date === '2026-06-13')!.deepMin).toBe(58);
  });

  it('round-trips the workouts array as JSON', () => {
    const dir = mkdtempSync(join(tmpdir(), 'hdb-'));
    const db = openHealthDb(join(dir, 'health.db'));
    const d = { date: '2026-06-13', workouts: [{ type: 'run', startISO: 'x', durationMin: 30 }] } as HealthUploadDay;
    upsertHealthDays(db, [d]);
    expect(readHealthDays(db)[0].workouts).toEqual(d.workouts);
  });
});
```

- [ ] **Step 2: Run — expect FAIL**

Run: `pnpm exec vitest run src/channels/ios-app/v2/health-db.test.ts`
Expected: FAIL — cannot find `./health-db.js`.

- [ ] **Step 3: Implement `health-db.ts`**

```ts
// Per-agent health store. Replaces raw.jsonl: one row per date (upsert),
// killing the duplicate-append bloat. Host writes (better-sqlite3); Greg's
// analyze.js reads the same file via bun:sqlite. journal_mode=DELETE so the
// container sees writes through the bind-mount (same rule as session DBs).
import Database from 'better-sqlite3';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

import type { HealthUploadDay } from '../../../../shared/ios-app-protocol/index.js';

// Scalar upload fields that map 1:1 to columns. `workouts` (array) and
// `ingested_at` are handled separately. Analyze-derived fields (recovery,
// hrvEff, sleepRegularity, fatMassKg…) are NOT stored — recomputed each run.
const SCALARS = [
  'steps', 'activeEnergy', 'exerciseMinutes', 'heartRate', 'restingHeartRate',
  'walkingHeartRateAverage', 'sleepHours', 'deepMin', 'remMin', 'coreMin',
  'awakeMin', 'sleepOnsetMin', 'hrv', 'hrvMorning', 'spo2Avg', 'spo2Min',
  'respiratoryRate', 'vo2max', 'wristTempDeviation', 'bodyMass', 'height',
  'bodyFatPercentage', 'leanBodyMass',
] as const;

export function openHealthDb(path: string): Database.Database {
  mkdirSync(dirname(path), { recursive: true });
  const db = new Database(path);
  db.pragma('journal_mode = DELETE');
  db.exec(
    `CREATE TABLE IF NOT EXISTS health_days (
       date TEXT PRIMARY KEY,
       ${SCALARS.map((c) => `${c} REAL`).join(', ')},
       workouts TEXT,
       ingested_at INTEGER
     )`,
  );
  return db;
}

export function upsertHealthDays(db: Database.Database, days: HealthUploadDay[]): void {
  const cols = ['date', ...SCALARS, 'workouts', 'ingested_at'];
  const placeholders = cols.map((c) => `@${c}`).join(', ');
  const updates = cols.filter((c) => c !== 'date').map((c) => `${c}=excluded.${c}`).join(', ');
  const stmt = db.prepare(
    `INSERT INTO health_days (${cols.join(', ')}) VALUES (${placeholders})
     ON CONFLICT(date) DO UPDATE SET ${updates}`,
  );
  const now = Date.now();
  const tx = db.transaction((rows: HealthUploadDay[]) => {
    for (const d of rows) {
      const rec: Record<string, unknown> = { date: d.date, ingested_at: now };
      for (const c of SCALARS) rec[c] = (d as Record<string, unknown>)[c] ?? null;
      rec.workouts = d.workouts ? JSON.stringify(d.workouts) : null;
      stmt.run(rec);
    }
  });
  tx(days);
}

export function readHealthDays(db: Database.Database): HealthUploadDay[] {
  const rows = db.prepare('SELECT * FROM health_days ORDER BY date').all() as Record<string, unknown>[];
  return rows.map((r) => {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(r)) {
      if (k === 'workouts') out.workouts = typeof v === 'string' ? JSON.parse(v) : undefined;
      else if (v !== null) out[k] = v;
    }
    return out as unknown as HealthUploadDay;
  });
}
```

- [ ] **Step 4: Run — expect PASS**

Run: `pnpm exec vitest run src/channels/ios-app/v2/health-db.test.ts`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app/v2/health-db.ts src/channels/ios-app/v2/health-db.test.ts
git commit -m "feat(host): per-agent health.db store (upsert by date)"
```

### Task 4: One-time migration `raw.jsonl` → `health.db`

**Files:**
- Create: `src/channels/ios-app/v2/health-migrate.ts`
- Test: `src/channels/ios-app/v2/health-migrate.test.ts`
- Modify: `src/index.ts` (call on startup, after migrations)

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from 'vitest';
import { mkdtempSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { migrateRawJsonlToDb } from './health-migrate.js';
import { openHealthDb, readHealthDays } from './health-db.js';

describe('health-migrate', () => {
  it('collapses duplicate dates, keeping the row with max sleepHours', () => {
    const dir = mkdtempSync(join(tmpdir(), 'hmig-'));
    const jsonl =
      JSON.stringify({ date: '2026-06-13', deepMin: 28, sleepHours: 6.0 }) + '\n' +
      JSON.stringify({ date: '2026-06-13', deepMin: 58, sleepHours: 6.9 }) + '\n' + // fuller backfill
      JSON.stringify({ date: '2026-06-12', deepMin: 49, sleepHours: 8.0 }) + '\n';
    writeFileSync(join(dir, 'raw.jsonl'), jsonl);

    migrateRawJsonlToDb(dir);

    const rows = readHealthDays(openHealthDb(join(dir, 'health.db')));
    expect(rows.map((r) => r.date)).toEqual(['2026-06-12', '2026-06-13']);
    expect(rows.find((r) => r.date === '2026-06-13')!.deepMin).toBe(58); // max-sleepHours row
    expect(existsSync(join(dir, 'raw.jsonl'))).toBe(false);            // renamed away
    expect(readdirSync(dir).some((f) => f.startsWith('raw.jsonl.migrated-'))).toBe(true);
  });

  it('is a no-op when health.db already exists', () => {
    const dir = mkdtempSync(join(tmpdir(), 'hmig-'));
    openHealthDb(join(dir, 'health.db')).close();
    writeFileSync(join(dir, 'raw.jsonl'), JSON.stringify({ date: '2026-06-13', sleepHours: 5 }) + '\n');
    migrateRawJsonlToDb(dir);
    expect(existsSync(join(dir, 'raw.jsonl'))).toBe(true); // untouched
  });
});
```

- [ ] **Step 2: Run — expect FAIL**

Run: `pnpm exec vitest run src/channels/ios-app/v2/health-migrate.test.ts`
Expected: FAIL — cannot find `./health-migrate.js`.

- [ ] **Step 3: Implement `health-migrate.ts`**

```ts
// One-time: fold a duplicate-laden raw.jsonl into health.db. Per date keep the
// row with the highest sleepHours (proxy for "fullest backfill" — partly undoes
// the pre-P1 pre-midnight undercount). Backs up the jsonl, never deletes it.
import fs from 'node:fs';
import path from 'node:path';

import { getAllAgentGroups } from '../../../db/agent-groups.js';
import { GROUPS_DIR } from '../../../config.js';
import { log } from '../../../log.js';
import type { HealthUploadDay } from '../../../../shared/ios-app-protocol/index.js';
import { openHealthDb, upsertHealthDays } from './health-db.js';

export function migrateRawJsonlToDb(healthDir: string): void {
  const dbPath = path.join(healthDir, 'health.db');
  const jsonlPath = path.join(healthDir, 'raw.jsonl');
  if (fs.existsSync(dbPath)) return;          // already migrated
  if (!fs.existsSync(jsonlPath)) return;      // nothing to migrate

  const best = new Map<string, HealthUploadDay>();
  for (const line of fs.readFileSync(jsonlPath, 'utf8').split('\n')) {
    const s = line.trim();
    if (!s) continue;
    let r: HealthUploadDay;
    try { r = JSON.parse(s) as HealthUploadDay; } catch { continue; }
    if (!r || !r.date) continue;
    const prev = best.get(r.date);
    const better = !prev || (r.sleepHours ?? -1) > (prev.sleepHours ?? -1);
    if (better) best.set(r.date, r);
  }

  const db = openHealthDb(dbPath);
  upsertHealthDays(db, [...best.values()]);
  db.close();
  fs.renameSync(jsonlPath, `${jsonlPath}.migrated-${Date.now()}`);
  log.info('Migrated health raw.jsonl → health.db', { healthDir, dates: best.size });
}

/** Migrate every agent group's health folder. Idempotent. */
export function migrateHealthStores(): void {
  for (const group of getAllAgentGroups()) {
    migrateRawJsonlToDb(path.join(GROUPS_DIR, group.folder, 'health'));
  }
}
```

- [ ] **Step 4: Run — expect PASS**

Run: `pnpm exec vitest run src/channels/ios-app/v2/health-migrate.test.ts`
Expected: PASS.

- [ ] **Step 5: Wire into startup**

In `src/index.ts`, find where `backfillContainerConfigs()` is called (after migrations) and add directly after it:

```ts
  migrateHealthStores();
```

Add the import near the other `./channels/ios-app/...` or backfill imports:

```ts
import { migrateHealthStores } from './channels/ios-app/v2/health-migrate.js';
```

- [ ] **Step 6: Build host to verify wiring compiles**

Run: `pnpm run build`
Expected: success, no TS errors.

- [ ] **Step 7: Commit**

```bash
git add src/channels/ios-app/v2/health-migrate.ts src/channels/ios-app/v2/health-migrate.test.ts src/index.ts
git commit -m "feat(host): migrate health raw.jsonl to health.db on startup"
```

### Task 5: Switch host ingest + sick-day reader to `health.db`

**Files:**
- Modify: `src/channels/ios-app/v2/health-ingest.ts` (`appendHealthHistory`)
- Modify: `src/channels/ios-app/v2/http-handler.ts` (`loadAllHealthRows`, lines 32-48)
- Check test: `src/channels/ios-app/v2/http-routes.test.ts`

- [ ] **Step 1: Rewrite `appendHealthHistory` to upsert**

Replace the body of `src/channels/ios-app/v2/health-ingest.ts`:

```ts
// Persist health-history rows to the per-group health.db (upsert by date),
// replacing the duplicate-append raw.jsonl. Producer: POST /ios/health/upload.
// Consumer: Greg's analyze.js (reads the same file via bun:sqlite).
import { join } from 'node:path';

import type { HealthUploadDay } from '../../../../shared/ios-app-protocol/index.js';
import { openHealthDb, upsertHealthDays } from './health-db.js';

export function appendHealthHistory(groupsDir: string, agentGroupFolder: string, days: HealthUploadDay[]): void {
  if (days.length === 0) return;
  const db = openHealthDb(join(groupsDir, agentGroupFolder, 'health', 'health.db'));
  try {
    upsertHealthDays(db, days);
  } finally {
    db.close();
  }
}
```

- [ ] **Step 2: Switch `loadAllHealthRows` to read `health.db`**

In `src/channels/ios-app/v2/http-handler.ts`, replace `loadAllHealthRows` (lines 32-48):

```ts
function loadAllHealthRows(groupsDir: string, agentFolder: string): HealthUploadDay[] {
  const path = join(groupsDir, agentFolder, 'health', 'health.db');
  if (!existsSync(path)) return [];
  const db = openHealthDb(path);
  try {
    return readHealthDays(db); // already sorted oldest→newest by date
  } finally {
    db.close();
  }
}
```

Update imports at the top of `http-handler.ts`: remove the now-unused `readFileSync` if nothing else uses it, and add:

```ts
import { openHealthDb, readHealthDays } from './health-db.js';
```

- [ ] **Step 3: Run the existing route tests**

Run: `pnpm exec vitest run src/channels/ios-app/v2/http-routes.test.ts`
Expected: PASS. If a test asserted raw.jsonl contents, update it to open `health.db` with `readHealthDays` and assert rows there instead.

- [ ] **Step 4: Build host**

Run: `pnpm run build`
Expected: success.

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app/v2/health-ingest.ts src/channels/ios-app/v2/http-handler.ts src/channels/ios-app/v2/http-routes.test.ts
git commit -m "feat(host): ingest + sick-day read from health.db"
```

### Task 6: `analyze.js` reads from `health.db`

**Files:**
- Modify: `groups/greg/scripts/analyze.js` (imports line 17, `parseModeArgs` default line 212, `loadRows` lines 234-245)
- Test: `groups/greg/scripts/analyze.test.js`

- [ ] **Step 1: Write the failing test**

Add to `analyze.test.js`:

```js
import { test, expect } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadRows } from "./analyze.js";

test("loadRows reads health_days from a .db path", () => {
  const dir = mkdtempSync(join(tmpdir(), "an-"));
  const p = join(dir, "health.db");
  const db = new Database(p);
  db.exec("CREATE TABLE health_days (date TEXT PRIMARY KEY, deepMin REAL, workouts TEXT, ingested_at INTEGER)");
  db.query("INSERT INTO health_days (date, deepMin, workouts) VALUES (?,?,?)")
    .run("2026-06-13", 58, JSON.stringify([{ type: "run" }]));
  db.close();
  const rows = loadRows(p);
  expect(rows.length).toBe(1);
  expect(rows[0].deepMin).toBe(58);
  expect(rows[0].workouts).toEqual([{ type: "run" }]);
});
```

(Requires `loadRows` to be exported — see Step 3.)

- [ ] **Step 2: Run — expect FAIL**

Run: `cd groups/greg/scripts && bun test analyze.test.js`
Expected: FAIL — `loadRows` not exported / `.db` not handled.

- [ ] **Step 3: Implement DB reading in `analyze.js`**

Add to the top imports (line 17 area):

```js
import { Database } from "bun:sqlite";
```

Change the `parseModeArgs` default (line 212):

```js
  const o = { raw: "/workspace/agent/health/health.db", mode: "normal",
```

Replace `loadRows` (lines 234-245) and export it:

```js
export function loadRows(path) {
  if (path.endsWith(".db")) return loadRowsFromDb(path);
  let text;
  try { text = readFileSync(path, "utf8"); } catch { return []; }
  const byDate = new Map(); // last line per date wins (legacy jsonl / fixtures)
  for (const line of text.split("\n")) {
    const s = line.trim();
    if (!s) continue;
    let r; try { r = JSON.parse(s); } catch { continue; }
    if (r && r.date) byDate.set(r.date, r);
  }
  return [...byDate.keys()].sort().map((d) => byDate.get(d));
}

function loadRowsFromDb(path) {
  let db;
  try { db = new Database(path, { readonly: true }); } catch { return []; }
  let rows;
  try { rows = db.query("SELECT * FROM health_days ORDER BY date").all(); }
  catch { db.close(); return []; }
  db.close();
  for (const r of rows) {
    if (typeof r.workouts === "string") {
      try { r.workouts = JSON.parse(r.workouts); } catch { r.workouts = []; }
    }
    for (const k of Object.keys(r)) if (r[k] === null) delete r[k];
  }
  return rows;
}
```

- [ ] **Step 4: Run — expect PASS** (and the existing suite stays green)

Run: `cd groups/greg/scripts && bun test analyze.test.js`
Expected: PASS (new test + existing fixture-based tests, which pass `.jsonl` paths through the legacy branch).

- [ ] **Step 5: Commit**

```bash
git add groups/greg/scripts/analyze.js groups/greg/scripts/analyze.test.js
git commit -m "feat(greg): analyze.js reads health.db, jsonl fallback for fixtures"
```

---

## Phase P3 — A1: levels, profiles parser & `GET /ios/state`

### Task 7: `computeLevels` + `recovery7d` in `analyze.js`

**Files:**
- Modify: `groups/greg/scripts/analyze.js` (add `computeLevels`/`recovery7dSeries` near `computeReadiness` line 306; add to result object lines 489-518)
- Test: `groups/greg/scripts/analyze.test.js`

- [ ] **Step 1: Write the failing test**

```js
import { computeLevels, recovery7dSeries } from "./analyze.js";

test("computeLevels returns 0-100 energy/stress/recovery/readiness", () => {
  const rows = [];
  for (let i = 0; i < 21; i++) rows.push({ date: `2026-05-${String(i + 1).padStart(2, "0")}`, hrvEff: 50, restingHeartRate: 60, sleepHours: 7.5, recovery: 0 });
  // last day: good sleep, HRV above base, RHR at base
  rows.push({ date: "2026-06-01", hrvEff: 60, restingHeartRate: 60, sleepHours: 8, deepMin: 90, remMin: 90, recovery: 1.0 });
  const lv = computeLevels(rows, { ratio: 1.0 }, { score: 72 });
  for (const k of ["energy", "stress", "recovery"]) {
    expect(lv[k]).toBeGreaterThanOrEqual(0);
    expect(lv[k]).toBeLessThanOrEqual(100);
  }
  expect(lv.readiness).toBe(72);
  expect(lv.stress).toBeLessThan(40); // good day = low stress
});

test("recovery7dSeries maps last 7 recovery z-scores to 0-100", () => {
  const rows = Array.from({ length: 9 }, (_, i) => ({ date: `d${i}`, recovery: 0 }));
  const s = recovery7dSeries(rows);
  expect(s.length).toBe(7);
  expect(s.every((v) => v >= 0 && v <= 100)).toBe(true);
});
```

- [ ] **Step 2: Run — expect FAIL**

Run: `cd groups/greg/scripts && bun test analyze.test.js`
Expected: FAIL — `computeLevels` not exported.

- [ ] **Step 3: Implement the functions**

Add after `computeReadiness` (line 314):

```js
// Provisional 0-100 levels for the app state board. energy/stress are NEW and
// uncalibrated (like readiness): publish as reference, do not let them override
// recovery/anomaly logic. Constants to be tuned on real data.
const clamp01 = (x) => Math.max(0, Math.min(1, x));
// recovery z (~-2..+2) → 0..1
const recNorm = (z) => clamp01(0.5 + (typeof z === "number" ? z : 0) / 4);

export function computeLevels(rows, load, readiness) {
  const last = rows.length ? rows[rows.length - 1] : null;
  if (!last) return null;
  const vals = (m) => rows.map((r) => r[m]).filter((v) => typeof v === "number" && Number.isFinite(v));
  const baseHrv = median(vals("hrvEff").slice(-21)) || median(vals("hrv").slice(-21)) || null;
  const baseRhr = median(vals("restingHeartRate").slice(-21)) || null;
  const target = 7.5;
  const hrvNow = typeof last.hrvEff === "number" ? last.hrvEff
               : typeof last.hrv === "number" ? last.hrv : null;
  const rhrNow = typeof last.restingHeartRate === "number" ? last.restingHeartRate : null;
  const sleep = typeof last.sleepHours === "number" ? last.sleepHours : null;
  const ratio = load && typeof load.ratio === "number" ? load.ratio : 1;

  const sHrv = (baseHrv && hrvNow) ? clamp01((baseHrv - hrvNow) / baseHrv) : 0;
  const sRhr = (baseRhr && rhrNow) ? clamp01(((rhrNow - baseRhr) / baseRhr) * 2) : 0;
  const sSleep = sleep != null ? clamp01((target - sleep) / target) : 0;
  const stress = Math.round(100 * (0.5 * sHrv + 0.3 * sRhr + 0.2 * sSleep));

  const eSleep = sleep != null ? clamp01(sleep / target) : 0.5;
  const deep = typeof last.deepMin === "number" ? last.deepMin : 0;
  const rem = typeof last.remMin === "number" ? last.remMin : 0;
  const eQuality = clamp01((deep + rem) / 180);
  const eRecovery = recNorm(last.recovery);
  const eDrain = clamp01(ratio - 1) / 1; // ratio 1→2 maps 0→1
  const energy = Math.round(100 * clamp01(0.35 * eSleep + 0.20 * eQuality + 0.45 * eRecovery - 0.25 * eDrain));

  return {
    energy, stress,
    recovery: Math.round(recNorm(last.recovery) * 100),
    readiness: readiness ? readiness.score : null,
  };
}

// Last 7 days of recovery, normalized 0-100 (for the app mini-trend sparkline).
export function recovery7dSeries(rows) {
  return rows.slice(-7).map((r) => Math.round(recNorm(r.recovery) * 100));
}
```

- [ ] **Step 4: Add `levels` + `recovery7d` to the normal-mode result**

In the `import.meta.main` block, before `result = {` (line 489) add:

```js
    const readiness = computeReadiness(rows, load);
    const levels = computeLevels(rows, load, readiness);
```

Then in the result object change line 518 `readiness: computeReadiness(rows, load),` to:

```js
      readiness,
      levels,
      recovery7d: recovery7dSeries(rows),
```

- [ ] **Step 5: Run — expect PASS**

Run: `cd groups/greg/scripts && bun test analyze.test.js`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add groups/greg/scripts/analyze.js groups/greg/scripts/analyze.test.js
git commit -m "feat(greg): compute energy/stress levels + recovery7d series"
```

### Task 8: `public.md` contract — agents publish `summary` (+ Greg `levels`)

**Files:**
- Modify: `groups/greg/skills/publish/SKILL.md`
- Modify: `groups/gordon/skills/publish/SKILL.md`, `groups/payne/skills/publish/SKILL.md`, `groups/scrooge/skills/publish/SKILL.md`, and Jarvis's publish step (search: `rg -l "memories/public.md" groups/*/skills`)

> No automated test — these are agent instruction files (markdown). Verification is the endpoint parser test (Task 9) against a sample fragment.

- [ ] **Step 1: Update Greg's publish skill**

In `groups/greg/skills/publish/SKILL.md`, change step 2 to also read `levels` and `recovery7d`, and replace the public.md template (step 3) frontmatter:

```
---
updated: <generated_at, YYYY-MM-DD>
summary: <latest_line дословно>
levels: {energy: <levels.energy>, stress: <levels.stress>, recovery: <levels.recovery>, readiness: <levels.readiness>}
recovery7d: <recovery7d как JSON-массив, напр. [74,77,72,80,79,85,81]>
---
# Greg — здоровье
...(тело без изменений)...
```

Add a discipline bullet: "`levels`/`recovery7d` — копируй из вывода analyze.js дословно; не считай руками."

- [ ] **Step 2: Update the other agents' publish skills**

For Gordon, Payne, Scrooge, and Jarvis: add a `summary:` frontmatter line to the `public.md` each writes — one plain-language sentence that fits the collapsed board row. Example for Gordon:

```
---
updated: <date>
summary: Рекомп идёт: сухая ↑, жир ↓ при ровном весе. Белок сегодня <p>/<target> г.
---
...(existing body becomes the accordion detail)...
```

Keep each agent's existing body content (it becomes the accordion `detail`).

- [ ] **Step 3: Commit**

```bash
git add groups/greg/skills/publish/SKILL.md groups/gordon/skills/publish/SKILL.md groups/payne/skills/publish/SKILL.md groups/scrooge/skills/publish/SKILL.md
git commit -m "docs(agents): public.md contract — summary + Greg levels frontmatter"
```

> Note: `groups/` is synced to the VDS by scp (not git) per project workflow — deploy these edited skills to the running agents separately.

### Task 9: Profiles parser (host)

**Files:**
- Create: `src/channels/ios-app/v2/profiles.ts`
- Test: `src/channels/ios-app/v2/profiles.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from 'vitest';
import { parseProfile } from './profiles.js';

const greg = `---
updated: 2026-06-12
summary: Сон 6.2ч, пульс покоя 66, вариабельность ровная. Флагов нет.
levels: {energy: 72, stress: 34, recovery: 81, readiness: 68}
recovery7d: [74, 77, 72, 80, 79, 85, 81]
---
- Пульс покоя: 66 (норма)
- Вариабельность: 55 (выше базы)
`;

describe('parseProfile', () => {
  it('extracts frontmatter fields, levels, and the body as detail', () => {
    const p = parseProfile('greg', greg);
    expect(p.updated).toBe('2026-06-12');
    expect(p.summary).toContain('Сон 6.2ч');
    expect(p.levels).toEqual({ energy: 72, stress: 34, recovery: 81, readiness: 68 });
    expect(p.recovery7d).toEqual([74, 77, 72, 80, 79, 85, 81]);
    expect(p.detail.trim().startsWith('- Пульс покоя')).toBe(true);
  });

  it('tolerates a fragment with no frontmatter', () => {
    const p = parseProfile('x', '# just a body\nhello');
    expect(p.summary).toBeNull();
    expect(p.detail).toContain('hello');
  });
});
```

- [ ] **Step 2: Run — expect FAIL**

Run: `pnpm exec vitest run src/channels/ios-app/v2/profiles.test.ts`
Expected: FAIL — cannot find `./profiles.js`.

- [ ] **Step 3: Implement `profiles.ts`**

```ts
// Parse a projected agent profile (groups/global/profiles/<key>.md) into the
// shape the /ios/state board renders. Frontmatter is a tiny convention:
// `updated:`, `summary:`, and (Greg only) inline `levels:` / `recovery7d:`.
// Body after frontmatter = accordion detail (raw markdown).
export interface Levels { energy: number | null; stress: number | null; recovery: number | null; readiness: number | null; }
export interface ParsedProfile {
  key: string;
  updated: string | null;
  summary: string | null;
  detail: string;
  levels: Levels | null;
  recovery7d: number[] | null;
}

function parseInlineLevels(s: string): Levels | null {
  const num = (k: string): number | null => {
    const m = s.match(new RegExp(`${k}\\s*:\\s*(-?\\d+(?:\\.\\d+)?)`));
    return m ? Number(m[1]) : null;
  };
  const energy = num('energy'), stress = num('stress'), recovery = num('recovery'), readiness = num('readiness');
  if (energy === null && stress === null && recovery === null && readiness === null) return null;
  return { energy, stress, recovery, readiness };
}

export function parseProfile(key: string, text: string): ParsedProfile {
  let updated: string | null = null;
  let summary: string | null = null;
  let levels: Levels | null = null;
  let recovery7d: number[] | null = null;
  let detail = text;

  const fm = text.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  if (fm) {
    const [, head, body] = fm;
    detail = body;
    for (const line of head.split('\n')) {
      const m = line.match(/^([A-Za-z0-9_]+)\s*:\s*(.*)$/);
      if (!m) continue;
      const [, k, v] = m;
      if (k === 'updated') updated = v.trim();
      else if (k === 'summary') summary = v.trim();
      else if (k === 'levels') levels = parseInlineLevels(v);
      else if (k === 'recovery7d') {
        try { recovery7d = JSON.parse(v.trim()); } catch { recovery7d = null; }
      }
    }
  }
  return { key, updated, summary, detail, levels, recovery7d };
}
```

- [ ] **Step 4: Run — expect PASS**

Run: `pnpm exec vitest run src/channels/ios-app/v2/profiles.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app/v2/profiles.ts src/channels/ios-app/v2/profiles.test.ts
git commit -m "feat(host): parser for projected agent profiles"
```

### Task 10: `GET /ios/state` endpoint

**Files:**
- Modify: `src/channels/ios-app/v2/http-handler.ts` (add route; add `groupsDir` is already a dep)
- Test: `src/channels/ios-app/v2/http-routes.test.ts`

- [ ] **Step 1: Write the failing test**

Add to `http-routes.test.ts` (follow the file's existing harness for mounting the handler + a bearer token; mirror the `/ios/health/requests` test setup):

```ts
it('GET /ios/state returns levels + ordered agent rows', async () => {
  // Arrange: write a couple of profiles into <groupsDir>/global/profiles/
  // (greg.md with levels, gordon.md with summary only) using the harness's groupsDir.
  // Then:
  const res = await request('GET', '/ios/state', { headers: { Authorization: `Bearer ${TOKEN}` } });
  expect(res.status).toBe(200);
  const body = JSON.parse(res.body);
  expect(body.levels.energy).toBe(72);
  expect(body.agents[0].key).toBe('greg');
  expect(body.agents.find((a) => a.key === 'gordon').summary).toContain('Рекомп');
});

it('GET /ios/state requires bearer auth', async () => {
  const res = await request('GET', '/ios/state', {});
  expect(res.status).toBe(401);
});
```

- [ ] **Step 2: Run — expect FAIL**

Run: `pnpm exec vitest run src/channels/ios-app/v2/http-routes.test.ts -t "ios/state"`
Expected: FAIL — route returns 404.

- [ ] **Step 3: Implement the route**

In `http-handler.ts`, add imports:

```ts
import { readdirSync } from 'node:fs';
import { parseProfile } from './profiles.js';
```

Add a static presentation map near the top of `createIosHttpHandler`:

```ts
  const AGENT_META: Record<string, { title: string; icon: string }> = {
    greg:    { title: 'Здоровье · Greg',     icon: '🩺' },
    gordon:  { title: 'Питание · Gordon',    icon: '🍽' },
    payne:   { title: 'Тренировки · Payne',  icon: '🏋' },
    scrooge: { title: 'Финансы · Scrooge',   icon: '💰' },
    jarvis:  { title: 'Фокус · Jarvis',      icon: '🧭' },
  };
  const AGENT_ORDER = ['greg', 'gordon', 'payne', 'scrooge', 'jarvis'];
```

Add the route handler (before the final 404 `res.writeHead(404…)`):

```ts
    if (req.method === 'GET' && url.pathname === '/ios/state') {
      if (!requireToken(req, res)) return;
      const profilesDir = join(groupsDir, 'global', 'profiles');
      const parsed = new Map<string, ReturnType<typeof parseProfile>>();
      try {
        for (const f of readdirSync(profilesDir)) {
          if (!f.endsWith('.md')) continue;
          const key = f.slice(0, -3);
          if (!AGENT_META[key]) continue;
          try {
            parsed.set(key, parseProfile(key, readFileSync(join(profilesDir, f), 'utf8')));
          } catch { /* skip unreadable fragment */ }
        }
      } catch { /* no profiles dir yet */ }

      const greg = parsed.get('greg');
      const levels = {
        energy: greg?.levels?.energy ?? null,
        stress: greg?.levels?.stress ?? null,
        recovery: greg?.levels?.recovery ?? null,
        readiness: greg?.levels?.readiness ?? null,
        recovery7d: greg?.recovery7d ?? null,
        updated: greg?.updated ?? null,
      };
      const agents = AGENT_ORDER.filter((k) => parsed.has(k)).map((k) => {
        const p = parsed.get(k)!;
        return {
          key: k,
          title: AGENT_META[k].title,
          icon: AGENT_META[k].icon,
          summary: p.summary,
          detail: p.detail,
          updated: p.updated,
        };
      });
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ levels, agents }));
      return;
    }
```

(`readFileSync` is already imported at the top of `http-handler.ts`.)

- [ ] **Step 4: Run — expect PASS**

Run: `pnpm exec vitest run src/channels/ios-app/v2/http-routes.test.ts -t "ios/state"`
Expected: PASS.

- [ ] **Step 5: Build host**

Run: `pnpm run build`
Expected: success.

- [ ] **Step 6: Commit**

```bash
git add src/channels/ios-app/v2/http-handler.ts src/channels/ios-app/v2/http-routes.test.ts
git commit -m "feat(host): GET /ios/state — levels + all-agent board rows"
```

---

## Phase P4 — A2: iOS state board

### Task 11: `StateModel` + `StateService`

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Models/StateModel.swift`
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/StateService.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/StateModelTests.swift`

- [ ] **Step 1: Write the failing decode test**

```swift
import XCTest
@testable import Jarvis

final class StateModelTests: XCTestCase {
    func testDecodesStatePayload() throws {
        let json = """
        {"levels":{"energy":72,"stress":34,"recovery":81,"readiness":68,"recovery7d":[74,77,81],"updated":"2026-06-12"},
         "agents":[{"key":"greg","title":"Здоровье · Greg","icon":"🩺","summary":"ok","detail":"- a","updated":"2026-06-12"}]}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(StateModel.self, from: json)
        XCTAssertEqual(s.levels.energy, 72)
        XCTAssertEqual(s.levels.recovery7d, [74, 77, 81])
        XCTAssertEqual(s.agents.first?.key, "greg")
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

Run: `cd ios/JarvisApp && xcodegen generate && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/StateModelTests`
Expected: FAIL — `StateModel` not found.

- [ ] **Step 3: Implement `StateModel.swift`**

```swift
import Foundation

struct StateModel: Codable, Equatable {
    struct Levels: Codable, Equatable {
        var energy: Int?; var stress: Int?; var recovery: Int?; var readiness: Int?
        var recovery7d: [Int]?; var updated: String?
    }
    struct AgentRow: Codable, Equatable, Identifiable {
        var key: String; var title: String; var icon: String
        var summary: String?; var detail: String?; var updated: String?
        var id: String { key }
    }
    var levels: Levels
    var agents: [AgentRow]
}
```

- [ ] **Step 4: Implement `StateService.swift`**

```swift
import Foundation

/// Fetches GET /ios/state. Mirrors HealthUpload's UserDefaults config
/// (serverURL/bearerToken) and ws→http normalization.
@MainActor
final class StateService: ObservableObject {
    @Published var state: StateModel?
    @Published var lastError: String?

    func refresh() {
        let defaults = UserDefaults.standard
        guard let server = defaults.string(forKey: "serverURL"), !server.isEmpty,
              let token = defaults.string(forKey: "bearerToken"), !token.isEmpty else { return }
        var base = server
        if base.hasPrefix("wss://") { base = "https://" + base.dropFirst(6) }
        else if base.hasPrefix("ws://") { base = "http://" + base.dropFirst(5) }
        else if !base.hasPrefix("http") { base = "http://" + base }
        guard let url = URL(string: base.hasSuffix("/") ? base + "ios/state" : base + "/ios/state") else { return }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let data, err == nil, let decoded = try? JSONDecoder().decode(StateModel.self, from: data) else {
                Task { @MainActor in self?.lastError = err?.localizedDescription ?? "decode failed" }
                return
            }
            Task { @MainActor in self?.state = decoded }
        }.resume()
    }
}
```

- [ ] **Step 5: Run — expect PASS**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/StateModelTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/StateModel.swift ios/JarvisApp/Sources/JarvisApp/Services/StateService.swift ios/JarvisApp/Sources/JarvisAppTests/StateModelTests.swift
git commit -m "feat(ios): StateModel + StateService for /ios/state"
```

### Task 12: `RingView` component

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Components/RingView.swift`

- [ ] **Step 1: Implement `RingView`**

```swift
import SwiftUI

/// A single 0-100 metric ring (conic-style progress + value + caption).
struct RingView: View {
    let value: Int?
    let caption: String
    let color: Color
    var size: CGFloat = 46

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.gray.opacity(0.22), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: CGFloat(value ?? 0) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value.map(String.init) ?? "—")
                    .font(.system(size: size * 0.28, weight: .bold))
                    .foregroundColor(.primary)
            }
            .frame(width: size, height: size)
            Text(caption).font(.system(size: 8)).foregroundColor(.secondary)
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd ios/JarvisApp && xcodegen generate && xcodebuild build -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Components/RingView.swift
git commit -m "feat(ios): RingView metric-ring component"
```

### Task 13: `StateBoardView` (rings + accordion rows + Greg mini-trend)

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Views/StateBoardView.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/StateBoardViewTests.swift`

- [ ] **Step 1: Write a smoke test (freshness label helper)**

The view exposes a pure freshness helper so logic is testable without rendering:

```swift
import XCTest
@testable import Jarvis

final class StateBoardViewTests: XCTestCase {
    func testFreshnessLabel() {
        XCTAssertEqual(StateBoardView.freshness(updated: "2026-06-13", today: "2026-06-13"), .today)
        XCTAssertEqual(StateBoardView.freshness(updated: "2026-06-12", today: "2026-06-13"), .stale)
        XCTAssertEqual(StateBoardView.freshness(updated: nil, today: "2026-06-13"), .unknown)
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

Run: `cd ios/JarvisApp && xcodegen generate && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/StateBoardViewTests`
Expected: FAIL — `StateBoardView` not found.

- [ ] **Step 3: Implement `StateBoardView.swift`**

```swift
import SwiftUI

struct StateBoardView: View {
    @ObservedObject var service: StateService
    @State private var expanded: Set<String> = []

    enum Freshness { case today, stale, unknown }
    static func freshness(updated: String?, today: String) -> Freshness {
        guard let u = updated else { return .unknown }
        return u == today ? .today : .stale
    }

    private static func todayKey() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    private func accent(_ key: String) -> Color {
        switch key {
        case "greg": return .green; case "gordon": return .orange
        case "payne": return .purple; case "scrooge": return .yellow
        default: return .blue
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let lv = service.state?.levels {
                    HStack(spacing: 14) {
                        RingView(value: lv.energy, caption: "энергия", color: .orange)
                        RingView(value: lv.stress, caption: "стресс", color: .teal)
                        RingView(value: lv.recovery, caption: "восст.", color: .green)
                        RingView(value: lv.readiness, caption: "готовн.", color: Color(red: 0.6, green: 0.84, blue: 0.29))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                ForEach(service.state?.agents ?? []) { a in
                    rowView(a)
                }
            }
        }
        .navigationTitle("Состояние")
        .onAppear { service.refresh() }
    }

    @ViewBuilder
    private func rowView(_ a: StateModel.AgentRow) -> some View {
        let isOpen = expanded.contains(a.key)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(a.icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.title).font(.system(size: 13, weight: .bold))
                    if let s = a.summary { Text(s).font(.system(size: 11)).foregroundColor(.secondary) }
                    if isOpen {
                        if let d = a.detail { Text(d).font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 2) }
                        if a.key == "greg", let series = service.state?.levels.recovery7d, series.count > 1 {
                            Sparkline(values: series).stroke(Color.green, lineWidth: 2).frame(height: 26).padding(.top, 4)
                        }
                    }
                }
                Spacer()
                Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.system(size: 10)).foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { if isOpen { expanded.remove(a.key) } else { expanded.insert(a.key) } }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .overlay(Rectangle().frame(width: 3).foregroundColor(accent(a.key)), alignment: .leading)
        .opacity(Self.freshness(updated: a.updated, today: Self.todayKey()) == .stale ? 0.6 : 1)
        Divider()
    }
}

/// Normalized 0-100 series → path in unit rect.
struct Sparkline: Shape {
    let values: [Int]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let maxV = max(values.max() ?? 100, 1)
        let step = rect.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: rect.minX + CGFloat(i) * step,
                             y: rect.maxY - (CGFloat(v) / CGFloat(maxV)) * rect.height)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}
```

- [ ] **Step 4: Run — expect PASS**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/StateBoardViewTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/StateBoardView.swift ios/JarvisApp/Sources/JarvisAppTests/StateBoardViewTests.swift
git commit -m "feat(ios): StateBoardView — rings + accordion agent rows"
```

### Task 14: Home strip + present board

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Components/HealthStripView.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift`

- [ ] **Step 1: Implement `HealthStripView`**

```swift
import SwiftUI

/// Compact 4-ring glance strip for the home screen. Taps open the full board.
struct HealthStripView: View {
    let levels: StateModel.Levels?
    var body: some View {
        HStack(spacing: 18) {
            RingView(value: levels?.energy, caption: "эн", color: .orange, size: 34)
            RingView(value: levels?.stress, caption: "стр", color: .teal, size: 34)
            RingView(value: levels?.recovery, caption: "вос", color: .green, size: 34)
            RingView(value: levels?.readiness, caption: "гот", color: Color(red: 0.6, green: 0.84, blue: 0.29), size: 34)
        }
        .padding(.vertical, 8).padding(.horizontal, 14)
        .background(Color.gray.opacity(0.12), in: Capsule())
    }
}
```

- [ ] **Step 2: Wire into `OrbHomeView`**

In `OrbHomeView` add a service + sheet state near the other `@State`/`@StateObject` declarations:

```swift
    @StateObject private var stateService = StateService()
    @State private var showStateBoard = false
```

Inside the home `VStack(spacing: 0)` (the orb column, ~line 96-107), just before the trailing `Spacer()`, insert the strip:

```swift
                HealthStripView(levels: stateService.state?.levels)
                    .onTapGesture { showStateBoard = true }
                    .padding(.bottom, Theme.scaled(12))
```

Attach the sheet + initial fetch to the outermost `ZStack` (after `.frame`/existing modifiers in `body`):

```swift
        .onAppear { stateService.refresh() }
        .sheet(isPresented: $showStateBoard) {
            NavigationView { StateBoardView(service: stateService) }
        }
```

- [ ] **Step 3: Regenerate project + build**

Run: `cd ios/JarvisApp && xcodegen generate && xcodebuild build -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Run the full app test suite**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Components/HealthStripView.swift ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift
git commit -m "feat(ios): home health strip → state board sheet"
```

---

## Deployment notes (post-implementation)

- **Host (P2/P3):** `pnpm run build && git push`, then on VDS `git pull && pnpm run build && systemctl --user restart nanoclaw`. Startup migration converts each agent's `raw.jsonl` → `health.db` once.
- **`analyze.js` + skills (P2/P3):** `groups/` is scp-synced (not git). Copy edited `groups/greg/scripts/analyze.js` and the `*/skills/publish/SKILL.md` files to the VDS. `analyze.js` is live-mounted — no image rebuild.
- **Greg session:** instruction/skill edits need a fresh SDK session to load (see MEMORY "Deploy Instruction Changes to Running Agent"). The `publish` skill is loaded per-run, so the next morning publish picks up the new template.
- **History correction:** after deploy, trigger one wide `health/requests` re-backfill from the rebuilt iOS app (P1 fix) so stored `deepMin` values are corrected for past dates.
- **iOS (P1/P4):** rebuild + install on device; verify a day with early sleep now shows correct `deepMin`, and the home strip + board render.

## Self-review notes

- **Spec coverage:** C → Tasks 1-2; B (schema/upsert/migrate/ingest/analyze read) → Tasks 3-6; A energy/stress → 7; contract → 8; parser → 9; endpoint → 10; iOS model/service/ring/board/strip → 11-14. All spec sections mapped.
- **Type consistency:** `openHealthDb`/`upsertHealthDays`/`readHealthDays` used identically across Tasks 3/5/6 reasoning; `loadRows` signature stable; `StateModel.Levels.recovery7d` consumed by `Sparkline` in Task 13 and produced by Task 7/10. `parseProfile` shape consumed by Task 10 matches Task 9.
- **Provisional:** energy/stress constants are uncalibrated by design (spec §2/§8) — published as reference, not authoritative.
