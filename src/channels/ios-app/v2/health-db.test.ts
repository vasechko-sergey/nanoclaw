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
