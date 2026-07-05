import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import Database from 'better-sqlite3';
import { runMigrations } from '../../db/migrations/index.js';
import { initTestDb, getDb, closeDb } from '../../db/connection.js';
import { upsertPersonTz } from '../person-tz/db.js';
import { getLastNotified } from './db.js';
import { runSummaryNotify } from './sweep.js';
import { DEFAULT_SUMMARY_CFG } from './detector.js';

let dir: string;
let db: Database.Database;
beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sumnotify-'));
  db = new Database(':memory:');
  runMigrations(db);
});
afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

// Build profiles/<agent>.md with a controlled mtime.
function writeCard(person: string, agent: string, mtimeMs: number) {
  const p = path.join(dir, person, 'global', 'profiles');
  fs.mkdirSync(p, { recursive: true });
  const f = path.join(p, `${agent}.md`);
  fs.writeFileSync(f, '---\nupdated: 2026-06-30\n---\nbody');
  fs.utimesSync(f, mtimeMs / 1000, mtimeMs / 1000);
}

const witaToUtcMs = (h: number, m: number) => Date.UTC(2026, 5, 30, h - 8, m, 0);

describe('runSummaryNotify', () => {
  it('fires once for the settled morning batch and persists the date', () => {
    writeCard('owner', 'jarvis', witaToUtcMs(8, 46));
    writeCard('owner', 'greg', witaToUtcMs(8, 47));
    writeCard('owner', 'payne', witaToUtcMs(8, 48));
    const calls: Array<{ p: string; c: number }> = [];

    runSummaryNotify({
      userMemoryBase: dir,
      db,
      nowMs: witaToUtcMs(8, 51), // settled (>3min after newest)
      cfg: DEFAULT_SUMMARY_CFG,
      emit: (personKey, payload) => calls.push({ p: personKey, c: payload.count }),
    });

    expect(calls).toEqual([{ p: 'owner', c: 3 }]);
    expect(getLastNotified(db, 'owner')).toBe('2026-06-30');

    // Second sweep same day → no re-fire.
    runSummaryNotify({
      userMemoryBase: dir,
      db,
      nowMs: witaToUtcMs(8, 55),
      cfg: DEFAULT_SUMMARY_CFG,
      emit: (p, pl) => calls.push({ p, c: pl.count }),
    });
    expect(calls).toHaveLength(1);
  });

  it('does not fire when no emitter-relevant cards / before settle', () => {
    writeCard('owner', 'jarvis', witaToUtcMs(8, 46));
    const calls: number[] = [];
    runSummaryNotify({
      userMemoryBase: dir,
      db,
      nowMs: witaToUtcMs(8, 47), // 1 min — not settled
      cfg: DEFAULT_SUMMARY_CFG,
      emit: () => calls.push(1),
    });
    expect(calls).toHaveLength(0);
    expect(getLastNotified(db, 'owner')).toBeNull();
  });

  it('resolves the per-owner tz into the detector cfg (Tokyo person)', () => {
    initTestDb();
    runMigrations(getDb());
    upsertPersonTz(getDb(), 'tokyo-person', 'Asia/Tokyo', '2026-06-30T00:00:00Z');
    try {
      const tokyoToUtcMs = (h: number, m: number) => Date.UTC(2026, 5, 30, h - 9, m, 0);
      writeCard('tokyo-person', 'jarvis', tokyoToUtcMs(8, 46));
      writeCard('tokyo-person', 'greg', tokyoToUtcMs(8, 47));
      const calls: Array<{ p: string; c: number }> = [];
      runSummaryNotify({
        userMemoryBase: dir,
        db: getDb(),
        nowMs: tokyoToUtcMs(8, 51), // settled, in Tokyo's window
        cfg: DEFAULT_SUMMARY_CFG, // default tz is Asia/Makassar — must be overridden per owner
        emit: (personKey, payload) => calls.push({ p: personKey, c: payload.count }),
      });
      expect(calls).toEqual([{ p: 'tokyo-person', c: 2 }]);
    } finally {
      closeDb();
    }
  });
});
