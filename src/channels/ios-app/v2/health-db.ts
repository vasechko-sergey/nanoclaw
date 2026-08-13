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
  'steps',
  'activeEnergy',
  'exerciseMinutes',
  'heartRate',
  'restingHeartRate',
  'walkingHeartRateAverage',
  'sleepHours',
  'deepMin',
  'remMin',
  'coreMin',
  'awakeMin',
  'sleepOnsetMin',
  'tzOffsetMin',
  'sleepOnsetUtcMs',
  'napMin',
  'napCount',
  'hrv',
  'hrvMorning',
  'spo2Avg',
  'spo2Min',
  'respiratoryRate',
  'vo2max',
  'wristTempDeviation',
  'bodyMass',
  'height',
  'bodyFatPercentage',
  'leanBodyMass',
  'bodyTemperature',
] as const;

// Upload fields that are JSON arrays, not scalars: stored as TEXT, parsed back
// on read. Kept as a list so the schema, the migration probe and the read path
// cannot drift apart the way `workouts` and the SCALARS block once could.
const JSON_COLS = ['symptoms', 'workouts'] as const;

export function openHealthDb(path: string): Database.Database {
  mkdirSync(dirname(path), { recursive: true });
  const db = new Database(path);
  db.pragma('journal_mode = DELETE');
  db.exec(
    `CREATE TABLE IF NOT EXISTS health_days (
       date TEXT PRIMARY KEY,
       ${SCALARS.map((c) => `${c} REAL`).join(', ')},
       ${JSON_COLS.map((c) => `${c} TEXT`).join(', ')},
       ingested_at INTEGER
     )`,
  );
  // The table predates every column added after its first release and has never
  // had a migration path — CREATE TABLE IF NOT EXISTS silently no-ops on an
  // existing file, so a new SCALARS entry would blow up the next upsert with
  // "table health_days has no column named X". Backfill additively; SQLite has
  // no IF NOT EXISTS for ADD COLUMN, so probe first.
  const existing = new Set(
    (db.prepare(`PRAGMA table_info(health_days)`).all() as { name: string }[]).map((c) => c.name),
  );
  const added: [string, string][] = [
    ...SCALARS.map((c) => [c, 'REAL'] as [string, string]),
    ...JSON_COLS.map((c) => [c, 'TEXT'] as [string, string]),
  ];
  for (const [col, type] of added) {
    if (!existing.has(col)) db.exec(`ALTER TABLE health_days ADD COLUMN ${col} ${type}`);
  }
  // Sub-daily buckets, in the same file so the container reads both through one
  // mount. A separate table rather than a JSON column on health_days: the rows
  // are queried by (date, metric) range, and burying ~192 objects a day inside a
  // TEXT blob would mean parsing every day to answer a question about one.
  db.exec(
    `CREATE TABLE IF NOT EXISTS health_intervals (
       date         TEXT    NOT NULL,
       metric       TEXT    NOT NULL,
       bucket_start INTEGER NOT NULL,
       bucket_min   INTEGER NOT NULL,
       n            INTEGER NOT NULL,
       mean         REAL    NOT NULL,
       lo           REAL,
       hi           REAL,
       stage        TEXT,
       PRIMARY KEY (date, metric, bucket_start)
     )`,
  );
  db.exec(`CREATE INDEX IF NOT EXISTS idx_intervals_date ON health_intervals(date)`);
  return db;
}

/**
 * Interval buckets for the given days. Replaces a day+metric WHOLESALE, which is
 * the opposite of `upsertHealthDays`'s COALESCE — and deliberately so. A daily
 * scalar arrives per metric and a partial upload must not erase the ones it is
 * silent about; a metric's buckets arrive as a complete set for the day or not
 * at all, so a re-upload that yields fewer of them has genuinely superseded the
 * old set and leaving the surplus behind would invent readings.
 *
 * The delete is per (date, metric), never per date: an upload carrying only
 * heartRate must not take the night's hrv buckets down with it.
 */
export function upsertHealthIntervals(db: Database.Database, days: HealthUploadDay[]): void {
  const del = db.prepare(`DELETE FROM health_intervals WHERE date = ? AND metric = ?`);
  const ins = db.prepare(
    `INSERT INTO health_intervals (date, metric, bucket_start, bucket_min, n, mean, lo, hi, stage)
     VALUES (@date, @metric, @bucket_start, @bucket_min, @n, @mean, @lo, @hi, @stage)`,
  );
  const tx = db.transaction((rows: HealthUploadDay[]) => {
    for (const d of rows) {
      if (!d.intervals?.length) continue;
      for (const metric of new Set(d.intervals.map((i) => i.metric))) del.run(d.date, metric);
      for (const iv of d.intervals) {
        ins.run({
          date: d.date,
          metric: iv.metric,
          bucket_start: iv.start,
          bucket_min: iv.min,
          n: iv.n,
          mean: iv.mean,
          lo: iv.lo ?? null,
          hi: iv.hi ?? null,
          stage: iv.stage ?? null,
        });
      }
    }
  });
  tx(days);
}

/**
 * Keep half a year. ~192 rows a day across four metrics caps the table near 35k
 * rows — small, but unbounded growth in a file the container opens on every run
 * is not worth the nothing it would buy.
 *
 * Compares the stored local-day string against SQLite's UTC `date('now')`. The
 * two can disagree by a day at the boundary, which at a 180-day horizon is
 * noise.
 */
export function pruneHealthIntervals(db: Database.Database, keepDays = 180): void {
  db.prepare(`DELETE FROM health_intervals WHERE date < date('now', ?)`).run(`-${keepDays} days`);
}

export function upsertHealthDays(db: Database.Database, days: HealthUploadDay[]): void {
  const cols = ['date', ...SCALARS, ...JSON_COLS, 'ingested_at'];
  const placeholders = cols.map((c) => `@${c}`).join(', ');
  // COALESCE, not a plain overwrite: an upload carrying a subset of the fields
  // would otherwise null out everything it omits. HealthKit answers per metric,
  // and a sync that runs before the watch has written the night's sleep sends a
  // day with no sleep fields at all — under a plain overwrite that erases a
  // night already on disk. A real value always wins; only nulls defer.
  //
  // The cost is that a value can never be un-set, which is the right trade for
  // this data: HealthKit does not retract a day it has already reported.
  // `ingested_at` is exempt — it is a write stamp and must always advance.
  const updates = cols
    .filter((c) => c !== 'date')
    .map((c) => (c === 'ingested_at' ? `${c}=excluded.${c}` : `${c}=COALESCE(excluded.${c}, health_days.${c})`))
    .join(', ');
  const stmt = db.prepare(
    `INSERT INTO health_days (${cols.join(', ')}) VALUES (${placeholders})
     ON CONFLICT(date) DO UPDATE SET ${updates}`,
  );
  const now = Date.now();
  const tx = db.transaction((rows: HealthUploadDay[]) => {
    for (const d of rows) {
      const rec: Record<string, unknown> = { date: d.date, ingested_at: now };
      for (const c of SCALARS) rec[c] = (d as Record<string, unknown>)[c] ?? null;
      // Serialize an empty array as '[]', not as null. Under COALESCE null means
      // "this upload says nothing about the field", so collapsing [] into it
      // would make a symptom list unclearable: delete a mis-logged fever in
      // Health.app and the stored one would outlive it forever. '[]' is a real
      // value and wins the COALESCE, which is what "checked, nothing" needs.
      for (const c of JSON_COLS) {
        const v = (d as Record<string, unknown>)[c];
        rec[c] = Array.isArray(v) ? JSON.stringify(v) : null;
      }
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
      if ((JSON_COLS as readonly string[]).includes(k)) {
        if (typeof v === 'string') out[k] = JSON.parse(v);
      } else if (v !== null) out[k] = v;
    }
    return out as unknown as HealthUploadDay;
  });
}
