import { describe, it, expect, beforeEach } from 'vitest';
import Database from 'better-sqlite3';
import { runMigrations } from '../../db/migrations/index.js';
import { getLastNotified, setLastNotified } from './db.js';

let db: Database.Database;
beforeEach(() => {
  db = new Database(':memory:');
  runMigrations(db);
});

describe('summary_notify_log', () => {
  it('returns null before any notify', () => {
    expect(getLastNotified(db, 'owner')).toBeNull();
  });
  it('upserts idempotently', () => {
    setLastNotified(db, 'owner', '2026-06-30');
    expect(getLastNotified(db, 'owner')).toBe('2026-06-30');
    setLastNotified(db, 'owner', '2026-07-01');
    expect(getLastNotified(db, 'owner')).toBe('2026-07-01');
  });
});
