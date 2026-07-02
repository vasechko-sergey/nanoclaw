import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import Database from 'better-sqlite3';

import { runMigrations } from '../../db/migrations/index.js';
import { initTestDb, getDb, closeDb } from '../../db/connection.js';
import type { Session } from '../../types.js';
import { insertGateEvent } from './db.js';
import { handleLogGateEvent } from './index.js';

describe('gate_events migration + insert', () => {
  let db: Database.Database;
  beforeEach(() => {
    db = new Database(':memory:');
    runMigrations(db);
  });

  it('migration 023 creates the table + index', () => {
    const table = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='gate_events'").get();
    expect(table).toBeTruthy();
    const idx = db
      .prepare("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_gate_events_created'")
      .get();
    expect(idx).toBeTruthy();
  });

  it('inserts and reads back a row', () => {
    insertGateEvent(db, {
      created_at: '2026-07-02T00:00:00Z',
      agent_group_id: 'scrooge',
      session_id: 's1',
      seq: 5,
      decision: 'refused_replacement',
      omit_id: 0,
      change_ratio: 0.82,
      age_ms: null,
      prev_len: 44,
      next_len: 120,
      prev_text: 'p',
      next_text: 'n',
    });
    const row = db.prepare('SELECT * FROM gate_events').get() as Record<string, unknown>;
    expect(row.decision).toBe('refused_replacement');
    expect(row.change_ratio).toBeCloseTo(0.82);
    expect(row.agent_group_id).toBe('scrooge');
    expect(row.omit_id).toBe(0);
  });
});

describe('handleLogGateEvent — session stamping', () => {
  beforeEach(() => {
    initTestDb();
    runMigrations(getDb());
  });
  afterEach(() => {
    closeDb();
  });

  it('stamps agent_group_id + session_id from the session (container never sends them)', async () => {
    const session = { id: 'sess-abc', agent_group_id: 'scrooge' } as unknown as Session;
    await handleLogGateEvent(
      {
        action: 'log_gate_event',
        decision: 'allowed',
        seq: 7,
        omitId: true,
        ratio: 0.42,
        ageMs: null,
        prevLen: 40,
        nextLen: 45,
        prev: 'old',
        next: 'new',
      },
      session,
    );
    const row = getDb().prepare('SELECT * FROM gate_events').get() as Record<string, unknown>;
    expect(row.agent_group_id).toBe('scrooge');
    expect(row.session_id).toBe('sess-abc');
    expect(row.decision).toBe('allowed');
    expect(row.omit_id).toBe(1);
    expect(row.change_ratio).toBeCloseTo(0.42);
    expect(row.seq).toBe(7);
  });

  it('coerces malformed fields to null instead of throwing', async () => {
    const session = { id: 's', agent_group_id: 'g' } as unknown as Session;
    await handleLogGateEvent(
      {
        action: 'log_gate_event',
        decision: 'refused_stale',
        omitId: false,
        ratio: 'nope',
        ageMs: 7200000,
        seq: null,
        prevLen: null,
        nextLen: 12,
        prev: null,
        next: 'x',
      },
      session,
    );
    const row = getDb().prepare('SELECT * FROM gate_events').get() as Record<string, unknown>;
    expect(row.change_ratio).toBeNull();
    expect(row.age_ms).toBe(7200000);
    expect(row.seq).toBeNull();
    expect(row.prev_text).toBeNull();
  });
});
