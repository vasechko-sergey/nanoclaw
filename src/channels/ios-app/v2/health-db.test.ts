import { describe, it, expect } from 'vitest';
import { mkdtempSync } from 'node:fs';
import Database from 'better-sqlite3';
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

describe('health-db — additive column migration', () => {
  it('adds new columns to a table created before they existed', () => {
    const dir = mkdtempSync(join(tmpdir(), 'hdb-mig-'));
    const path = join(dir, 'health.db');
    // A pre-migration table carrying only what the first release wrote.
    // CREATE TABLE IF NOT EXISTS no-ops on this, so without the ALTER probe the
    // next upsert throws "table health_days has no column named tzOffsetMin".
    const old = new Database(path);
    old.exec(`CREATE TABLE health_days (date TEXT PRIMARY KEY, steps REAL, workouts TEXT, ingested_at INTEGER)`);
    old.close();

    const db = openHealthDb(path);
    const names = new Set(
      (db.prepare('PRAGMA table_info(health_days)').all() as { name: string }[]).map((c) => c.name),
    );
    expect(names.has('tzOffsetMin')).toBe(true);
    expect(names.has('wristTempDeviation')).toBe(true);

    upsertHealthDays(db, [{ date: '2026-08-12', steps: 1847, tzOffsetMin: 330 } as HealthUploadDay]);
    expect(readHealthDays(db)[0].tzOffsetMin).toBe(330);
  });

  it('is a no-op on a table that already has every column', () => {
    const dir = mkdtempSync(join(tmpdir(), 'hdb-noop-'));
    const path = join(dir, 'health.db');
    openHealthDb(path);
    const db = openHealthDb(path);
    upsertHealthDays(db, [{ date: '2026-08-12', tzOffsetMin: 480 } as HealthUploadDay]);
    expect(readHealthDays(db)[0].tzOffsetMin).toBe(480);
  });

  it('round-trips the timezone offset, including a negative one', () => {
    const dir = mkdtempSync(join(tmpdir(), 'hdb-tz-'));
    const db = openHealthDb(join(dir, 'health.db'));
    upsertHealthDays(db, [
      { date: '2026-06-20', sleepOnsetMin: -77, tzOffsetMin: 480 },
      { date: '2026-07-02', sleepOnsetMin: -14, tzOffsetMin: 330 },
      { date: '2026-07-03', tzOffsetMin: -300 },
    ] as HealthUploadDay[]);
    expect(readHealthDays(db).map((r) => r.tzOffsetMin)).toEqual([480, 330, -300]);
  });
});
