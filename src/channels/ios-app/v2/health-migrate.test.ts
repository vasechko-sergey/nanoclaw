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
      JSON.stringify({ date: '2026-06-13', deepMin: 28, sleepHours: 6.0 }) +
      '\n' +
      JSON.stringify({ date: '2026-06-13', deepMin: 58, sleepHours: 6.9 }) +
      '\n' +
      JSON.stringify({ date: '2026-06-12', deepMin: 49, sleepHours: 8.0 }) +
      '\n';
    writeFileSync(join(dir, 'raw.jsonl'), jsonl);

    migrateRawJsonlToDb(dir);

    const rows = readHealthDays(openHealthDb(join(dir, 'health.db')));
    expect(rows.map((r) => r.date)).toEqual(['2026-06-12', '2026-06-13']);
    expect(rows.find((r) => r.date === '2026-06-13')!.deepMin).toBe(58);
    expect(existsSync(join(dir, 'raw.jsonl'))).toBe(false);
    expect(readdirSync(dir).some((f) => f.startsWith('raw.jsonl.migrated-'))).toBe(true);
  });

  it('is a no-op when health.db already exists', () => {
    const dir = mkdtempSync(join(tmpdir(), 'hmig-'));
    openHealthDb(join(dir, 'health.db')).close();
    writeFileSync(join(dir, 'raw.jsonl'), JSON.stringify({ date: '2026-06-13', sleepHours: 5 }) + '\n');
    migrateRawJsonlToDb(dir);
    expect(existsSync(join(dir, 'raw.jsonl'))).toBe(true);
  });
});
