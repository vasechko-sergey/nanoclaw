/**
 * Tests for core per-session messages_in schema maintenance.
 *
 * Task-specific DB tests (insertTask, cancel/pause/resume, updateTask,
 * insertRecurrence) live in `src/modules/scheduling/db.test.ts` with the
 * rest of the scheduling module.
 */
import Database from 'better-sqlite3';
import fs from 'fs';
import path from 'path';
import { describe, it, expect, afterEach } from 'vitest';

import { INBOUND_SCHEMA } from './schema.js';
import {
  getInboundSourceSessionId,
  migrateDestinationsTable,
  migrateMessagesInTable,
  replaceDestinations,
} from './session-db.js';

const TEST_DIR = '/tmp/nanoclaw-session-db-test';
const DB_PATH = path.join(TEST_DIR, 'inbound.db');

afterEach(() => {
  if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true });
});

describe('migrateMessagesInTable', () => {
  it('backfills series_id = id on legacy rows and is idempotent', () => {
    if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true });
    fs.mkdirSync(TEST_DIR, { recursive: true });

    // Build a legacy inbound.db WITHOUT series_id to simulate a pre-fix install.
    const db = new Database(DB_PATH);
    db.exec(`
      CREATE TABLE messages_in (
        id             TEXT PRIMARY KEY,
        seq            INTEGER UNIQUE,
        kind           TEXT NOT NULL,
        timestamp      TEXT NOT NULL,
        status         TEXT DEFAULT 'pending',
        process_after  TEXT,
        recurrence     TEXT,
        tries          INTEGER DEFAULT 0,
        platform_id    TEXT,
        channel_type   TEXT,
        thread_id      TEXT,
        content        TEXT NOT NULL
      );
    `);
    db.prepare(
      "INSERT INTO messages_in (id, seq, kind, timestamp, status, content) VALUES (?, ?, 'task', datetime('now'), 'pending', '{}')",
    ).run('legacy-1', 2);

    migrateMessagesInTable(db);
    migrateMessagesInTable(db); // idempotent

    const row = db.prepare('SELECT series_id FROM messages_in WHERE id = ?').get('legacy-1') as {
      series_id: string;
    };
    expect(row.series_id).toBe('legacy-1');
    db.close();
  });

  it('adds source_session_id on a legacy DB, leaves existing rows NULL, is idempotent', () => {
    if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true });
    fs.mkdirSync(TEST_DIR, { recursive: true });

    const db = new Database(DB_PATH);
    db.exec(`
      CREATE TABLE messages_in (
        id             TEXT PRIMARY KEY,
        seq            INTEGER UNIQUE,
        kind           TEXT NOT NULL,
        timestamp      TEXT NOT NULL,
        status         TEXT DEFAULT 'pending',
        process_after  TEXT,
        recurrence     TEXT,
        tries          INTEGER DEFAULT 0,
        platform_id    TEXT,
        channel_type   TEXT,
        thread_id      TEXT,
        content        TEXT NOT NULL
      );
    `);
    db.prepare(
      "INSERT INTO messages_in (id, seq, kind, timestamp, status, content) VALUES (?, ?, 'chat', datetime('now'), 'pending', '{}')",
    ).run('legacy-2', 2);

    migrateMessagesInTable(db);
    migrateMessagesInTable(db); // idempotent

    const cols = (db.prepare("PRAGMA table_info('messages_in')").all() as Array<{ name: string }>).map((c) => c.name);
    expect(cols).toContain('source_session_id');

    expect(getInboundSourceSessionId(db, 'legacy-2')).toBeNull();
    expect(getInboundSourceSessionId(db, 'does-not-exist')).toBeNull();
    db.close();
  });
});

describe('migrateDestinationsTable', () => {
  it('adds a2a_kinds to a destinations table created before the column existed', () => {
    const db = new Database(':memory:');
    // Baseline v2 destinations table — no a2a_kinds. `CREATE TABLE IF NOT
    // EXISTS` in INBOUND_SCHEMA would leave this shape untouched forever, so
    // the ALTER is the only thing that reaches an existing session DB.
    db.exec(`CREATE TABLE destinations (
      name            TEXT PRIMARY KEY,
      display_name    TEXT,
      type            TEXT NOT NULL,
      channel_type    TEXT,
      platform_id     TEXT,
      agent_group_id  TEXT
    )`);
    db.prepare(
      `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id)
       VALUES ('payne', 'Майор Пейн', 'agent', NULL, NULL, 'ag-1')`,
    ).run();

    migrateDestinationsTable(db);
    migrateDestinationsTable(db); // idempotent

    const cols = (db.prepare("PRAGMA table_info('destinations')").all() as Array<{ name: string }>).map((c) => c.name);
    expect(cols).toContain('a2a_kinds');
    // Pre-existing rows must land on NULL, not [] — a migrated row has no
    // descriptor knowledge, and NULL is what disarms the gate.
    const row = db.prepare('SELECT a2a_kinds FROM destinations WHERE name = ?').get('payne') as {
      a2a_kinds: string | null;
    };
    expect(row.a2a_kinds).toBeNull();
    db.close();
  });

  it('round-trips a2a_kinds through replaceDestinations', () => {
    const db = new Database(':memory:');
    db.exec(INBOUND_SCHEMA);

    replaceDestinations(db, [
      {
        name: 'payne',
        display_name: 'Майор Пейн',
        type: 'agent',
        channel_type: null,
        platform_id: null,
        agent_group_id: 'ag-1',
        a2a_kinds: '["set_log","ack"]',
      },
      {
        name: 'family',
        display_name: 'Семья',
        type: 'channel',
        channel_type: 'telegram',
        platform_id: '-100',
        agent_group_id: null,
        a2a_kinds: null,
      },
    ]);

    expect(db.prepare('SELECT name, a2a_kinds FROM destinations ORDER BY name').all()).toEqual([
      { name: 'family', a2a_kinds: null },
      { name: 'payne', a2a_kinds: '["set_log","ack"]' },
    ]);
    db.close();
  });
});
