import { describe, it, expect } from 'vitest';
import { mkdtempSync } from 'node:fs';
import Database from 'better-sqlite3';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  openHealthDb,
  upsertHealthDays,
  readHealthDays,
  upsertHealthIntervals,
  pruneHealthIntervals,
} from './health-db.js';
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

  it('adds the subjective-channel columns to a pre-existing table', () => {
    const dir = mkdtempSync(join(tmpdir(), 'hdb-symp-mig-'));
    const path = join(dir, 'health.db');
    const old = new Database(path);
    old.exec(`CREATE TABLE health_days (date TEXT PRIMARY KEY, steps REAL, workouts TEXT, ingested_at INTEGER)`);
    old.close();

    const db = openHealthDb(path);
    const names = new Set(
      (db.prepare('PRAGMA table_info(health_days)').all() as { name: string }[]).map((c) => c.name),
    );
    expect(names.has('bodyTemperature')).toBe(true);
    expect(names.has('symptoms')).toBe(true);

    upsertHealthDays(db, [{ date: '2026-08-12', bodyTemperature: 37.8, symptoms: ['fever'] } as HealthUploadDay]);
    const row = readHealthDays(db)[0];
    expect(row.bodyTemperature).toBe(37.8);
    expect(row.symptoms).toEqual(['fever']);
  });

  it('keeps symptoms an array through the JSON round-trip, and absent when unlogged', () => {
    const dir = mkdtempSync(join(tmpdir(), 'hdb-symp-'));
    const db = openHealthDb(join(dir, 'health.db'));
    upsertHealthDays(db, [
      { date: '2026-08-12', symptoms: ['fever', 'coughing', 'fatigue'] },
      { date: '2026-08-13', steps: 1847 },
    ] as HealthUploadDay[]);
    const rows = readHealthDays(db);
    expect(rows[0].symptoms).toEqual(['fever', 'coughing', 'fatigue']);
    expect(rows[1].symptoms).toBeUndefined();
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

describe('health-db — a partial upload does not erase what is already stored', () => {
  it('keeps fields the new payload omits', () => {
    const dir = mkdtempSync(join(tmpdir(), 'hdb-partial-'));
    const db = openHealthDb(join(dir, 'health.db'));
    upsertHealthDays(db, [
      { date: '2026-08-13', sleepHours: 6.3, deepMin: 30, remMin: 123, steps: 730 } as HealthUploadDay,
    ]);
    // A later sync that ran before the watch wrote the night: activity only.
    upsertHealthDays(db, [{ date: '2026-08-13', steps: 1149 } as HealthUploadDay]);
    const row = readHealthDays(db)[0];
    expect(row.steps).toBe(1149); // a real value still wins
    expect(row.sleepHours).toBe(6.3); // the night survives
    expect(row.deepMin).toBe(30);
    expect(row.remMin).toBe(123);
  });

  it('does not resurrect a symptom list the newer upload dropped', () => {
    // COALESCE defers to the stored value on null, which is right for scalars —
    // HealthKit does not retract a measurement. Symptoms it CAN retract: the
    // user deletes a mis-logged fever in Health.app and the re-upload carries an
    // empty day. Treat the array as an overwrite once the day carries the field.
    const dir = mkdtempSync(join(tmpdir(), 'hdb-symp-clear-'));
    const db = openHealthDb(join(dir, 'health.db'));
    upsertHealthDays(db, [{ date: '2026-08-12', symptoms: ['fever'] } as HealthUploadDay]);
    upsertHealthDays(db, [{ date: '2026-08-12', symptoms: [] } as HealthUploadDay]);
    expect(readHealthDays(db)[0].symptoms).toEqual([]);
  });

  it('still advances ingested_at on every write', () => {
    const dir = mkdtempSync(join(tmpdir(), 'hdb-stamp-'));
    const path = join(dir, 'health.db');
    const db = openHealthDb(path);
    upsertHealthDays(db, [{ date: '2026-08-13', steps: 730 } as HealthUploadDay]);
    const first = (db.prepare('SELECT ingested_at AS t FROM health_days').get() as { t: number }).t;
    db.prepare('UPDATE health_days SET ingested_at = ?').run(first - 10_000);
    upsertHealthDays(db, [{ date: '2026-08-13', steps: 1149 } as HealthUploadDay]);
    const second = (db.prepare('SELECT ingested_at AS t FROM health_days').get() as { t: number }).t;
    expect(second).toBeGreaterThan(first - 10_000);
  });
});

describe('health-db — interval buckets', () => {
  const iv = (metric: string, start: number, mean: number, extra: Record<string, unknown> = {}) =>
    ({ metric, start, min: 30, n: 10, mean, ...extra }) as never;

  it('stores buckets and replaces a metric wholesale on re-upload', () => {
    const dir = mkdtempSync(join(tmpdir(), 'hdb-iv-'));
    const db = openHealthDb(join(dir, 'health.db'));
    upsertHealthIntervals(db, [
      {
        date: '2026-08-12',
        intervals: [iv('heartRate', 1000, 60), iv('heartRate', 2_800_000, 58, { stage: 'deep' }), iv('hrv', 1000, 44)],
      },
    ] as HealthUploadDay[]);
    // A re-upload carrying one fewer heartRate bucket must not leave the old one
    // behind: buckets arrive as a complete set for the day, so a survivor is a
    // reading nothing measured.
    upsertHealthIntervals(db, [
      { date: '2026-08-12', intervals: [iv('heartRate', 1000, 61, { n: 11 })] },
    ] as HealthUploadDay[]);

    const hr = db.prepare(`SELECT * FROM health_intervals WHERE date=? AND metric='heartRate'`).all('2026-08-12') as {
      mean: number;
    }[];
    expect(hr).toHaveLength(1);
    expect(hr[0].mean).toBe(61);
    // hrv was absent from the second payload, so its buckets stand untouched.
    expect(db.prepare(`SELECT * FROM health_intervals WHERE date=? AND metric='hrv'`).all('2026-08-12')).toHaveLength(
      1,
    );
  });

  it('keeps lo/hi/stage nullable and round-trips them', () => {
    const dir = mkdtempSync(join(tmpdir(), 'hdb-iv-null-'));
    const db = openHealthDb(join(dir, 'health.db'));
    upsertHealthIntervals(db, [
      {
        date: '2026-08-12',
        intervals: [iv('heartRate', 0, 60, { lo: 54, hi: 63, stage: 'rem' }), iv('hrv', 0, 44)],
      },
    ] as HealthUploadDay[]);
    const rows = db.prepare(`SELECT metric, lo, hi, stage FROM health_intervals ORDER BY metric`).all() as {
      metric: string;
      lo: number | null;
      hi: number | null;
      stage: string | null;
    }[];
    expect(rows[0]).toEqual({ metric: 'heartRate', lo: 54, hi: 63, stage: 'rem' });
    expect(rows[1]).toEqual({ metric: 'hrv', lo: null, hi: null, stage: null });
  });

  it('is a no-op for a day carrying no intervals', () => {
    const dir = mkdtempSync(join(tmpdir(), 'hdb-iv-none-'));
    const db = openHealthDb(join(dir, 'health.db'));
    upsertHealthIntervals(db, [{ date: '2026-08-12', intervals: [iv('heartRate', 0, 60)] }] as HealthUploadDay[]);
    // Every day before this feature — and every day whose payload predates it —
    // arrives without the field. It must leave the stored buckets alone rather
    // than reading as "this day has none".
    upsertHealthIntervals(db, [{ date: '2026-08-12', steps: 900 }] as HealthUploadDay[]);
    expect(db.prepare(`SELECT count(*) AS n FROM health_intervals`).get()).toEqual({ n: 1 });
  });

  it('opens a health.db created before the interval table existed', () => {
    const dir = mkdtempSync(join(tmpdir(), 'hdb-iv-mig-'));
    const path = join(dir, 'health.db');
    const old = new Database(path);
    old.exec(`CREATE TABLE health_days (date TEXT PRIMARY KEY, steps REAL, ingested_at INTEGER)`);
    old.close();
    const db = openHealthDb(path);
    upsertHealthIntervals(db, [{ date: '2026-08-12', intervals: [iv('heartRate', 0, 60)] }] as HealthUploadDay[]);
    expect(db.prepare(`SELECT count(*) AS n FROM health_intervals`).get()).toEqual({ n: 1 });
  });

  it('prunes buckets older than the retention window and keeps the rest', () => {
    const dir = mkdtempSync(join(tmpdir(), 'hdb-iv-prune-'));
    const db = openHealthDb(join(dir, 'health.db'));
    const today = new Date().toISOString().slice(0, 10);
    upsertHealthIntervals(db, [
      { date: '2020-01-01', intervals: [iv('heartRate', 0, 60)] },
      { date: today, intervals: [iv('heartRate', 0, 62)] },
    ] as HealthUploadDay[]);
    pruneHealthIntervals(db);
    expect(db.prepare(`SELECT date FROM health_intervals`).all()).toEqual([{ date: today }]);
  });
});
