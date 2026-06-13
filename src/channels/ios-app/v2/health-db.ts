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
  const updates = cols
    .filter((c) => c !== 'date')
    .map((c) => `${c}=excluded.${c}`)
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
