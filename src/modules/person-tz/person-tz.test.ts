import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import Database from 'better-sqlite3';

import { runMigrations } from '../../db/migrations/index.js';
import { initTestDb, getDb, closeDb } from '../../db/connection.js';
import { upsertPersonTz, getPersonTz } from './db.js';
import { noteDeviceTz, resolveOwnerTz } from './index.js';

describe('migration 024 person_tz', () => {
  let db: Database.Database;
  beforeEach(() => {
    db = new Database(':memory:');
    runMigrations(db);
  });

  it('creates the person_tz table', () => {
    const t = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='person_tz'").get();
    expect(t).toBeTruthy();
  });
});

describe('person_tz db', () => {
  let db: Database.Database;
  beforeEach(() => {
    db = new Database(':memory:');
    runMigrations(db);
  });

  it('inserts then reads back a tz', () => {
    upsertPersonTz(db, 'p1', 'Europe/London', '2026-07-05T00:00:00Z');
    expect(getPersonTz(db, 'p1')).toBe('Europe/London');
  });

  it('returns null for an unknown person', () => {
    expect(getPersonTz(db, 'nobody')).toBeNull();
  });

  it('updates tz + updated_at when the zone changes', () => {
    upsertPersonTz(db, 'p1', 'Europe/London', '2026-07-05T00:00:00Z');
    upsertPersonTz(db, 'p1', 'Asia/Tokyo', '2026-07-06T00:00:00Z');
    const row = db.prepare('SELECT tz, updated_at FROM person_tz WHERE person_key=?').get('p1') as {
      tz: string;
      updated_at: string;
    };
    expect(row.tz).toBe('Asia/Tokyo');
    expect(row.updated_at).toBe('2026-07-06T00:00:00Z');
  });

  it('leaves updated_at untouched when the same zone is re-reported', () => {
    upsertPersonTz(db, 'p1', 'Europe/London', '2026-07-05T00:00:00Z');
    upsertPersonTz(db, 'p1', 'Europe/London', '2026-07-09T00:00:00Z');
    const row = db.prepare('SELECT updated_at FROM person_tz WHERE person_key=?').get('p1') as {
      updated_at: string;
    };
    expect(row.updated_at).toBe('2026-07-05T00:00:00Z'); // "here since" — unchanged
  });
});

describe('noteDeviceTz / resolveOwnerTz (via central getDb)', () => {
  beforeEach(() => {
    initTestDb();
    runMigrations(getDb());
  });
  afterEach(() => closeDb());

  it('stores a valid IANA tz and resolves it back', () => {
    noteDeviceTz('p1', 'Asia/Tokyo');
    expect(resolveOwnerTz('p1')).toBe('Asia/Tokyo');
  });

  it('ignores a non-IANA tz (no row, no throw)', () => {
    noteDeviceTz('p2', 'Mars/Phobos');
    noteDeviceTz('p2', '');
    expect(resolveOwnerTz('p2')).toBeNull();
  });

  it('resolveOwnerTz short-circuits to null on empty/undefined owner', () => {
    expect(resolveOwnerTz(null)).toBeNull();
    expect(resolveOwnerTz(undefined)).toBeNull();
    expect(resolveOwnerTz('')).toBeNull();
  });

  it('resolveOwnerTz returns null for an owner with no stored tz', () => {
    expect(resolveOwnerTz('never-reported')).toBeNull();
  });
});
