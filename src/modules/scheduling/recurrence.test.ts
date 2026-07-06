/**
 * Tests for `handleRecurrence` — specifically the timezone-aware cron
 * interpretation ported from v1 (src/v1/task-scheduler.ts).
 *
 * Core invariant: cron expressions are interpreted in the user's TIMEZONE,
 * not UTC. Without this, `"0 9 * * *"` fires at 09:00 UTC instead of 09:00
 * user-local — a recurring scheduling bug users can't diagnose.
 */
import fs from 'fs';
import path from 'path';
import { afterEach, describe, expect, it } from 'vitest';

import { ensureSchema, openInboundDb } from '../../db/session-db.js';
import { initTestDb, getDb, closeDb } from '../../db/connection.js';
import { runMigrations } from '../../db/migrations/index.js';
import { OWNER_PERSON_KEY } from '../../config.js';
import { upsertPersonTz } from '../person-tz/db.js';
import { insertTask } from './db.js';
import { handleRecurrence } from './recurrence.js';
import type { Session } from '../../types.js';

const TEST_DIR = '/tmp/nanoclaw-recurrence-test';
const DB_PATH = path.join(TEST_DIR, 'inbound.db');

function freshDb() {
  if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true });
  fs.mkdirSync(TEST_DIR, { recursive: true });
  ensureSchema(DB_PATH, 'inbound');
  return openInboundDb(DB_PATH);
}

function fakeSession(): Session {
  return {
    id: 'sess-test',
    agent_group_id: 'ag-test',
    messaging_group_id: 'mg-test',
    thread_id: null,
    status: 'active',
    created_at: new Date().toISOString(),
    last_active: new Date().toISOString(),
    container_status: 'stopped',
  } as Session;
}

afterEach(() => {
  if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true });
});

describe('handleRecurrence', () => {
  it('clones a completed recurring task with a next-run in the future', async () => {
    const db = freshDb();
    insertTask(db, {
      id: 'task-1',
      processAfter: '2020-01-01T00:00:00.000Z',
      recurrence: '0 9 * * *', // every day at 09:00 (user TZ)
      platformId: null,
      channelType: null,
      threadId: null,
      content: JSON.stringify({ prompt: 'daily digest' }),
    });
    db.prepare(`UPDATE messages_in SET status='completed' WHERE id='task-1'`).run();

    await handleRecurrence(db, fakeSession());

    const rows = db
      .prepare(`SELECT id, status, process_after, recurrence, series_id FROM messages_in ORDER BY seq`)
      .all() as Array<{
      id: string;
      status: string;
      process_after: string;
      recurrence: string | null;
      series_id: string;
    }>;
    expect(rows).toHaveLength(2);
    const original = rows.find((r) => r.id === 'task-1')!;
    const follow = rows.find((r) => r.id !== 'task-1')!;
    expect(original.recurrence).toBeNull();
    expect(follow.status).toBe('pending');
    expect(follow.recurrence).toBe('0 9 * * *');
    expect(follow.series_id).toBe('task-1');
    expect(new Date(follow.process_after).getTime()).toBeGreaterThan(Date.now());
  });

  it('does not clone rows whose recurrence is already cleared', async () => {
    const db = freshDb();
    insertTask(db, {
      id: 'task-1',
      processAfter: '2020-01-01T00:00:00.000Z',
      recurrence: null,
      platformId: null,
      channelType: null,
      threadId: null,
      content: JSON.stringify({ prompt: 'one-off' }),
    });
    db.prepare(`UPDATE messages_in SET status='completed' WHERE id='task-1'`).run();

    await handleRecurrence(db, fakeSession());

    const count = (db.prepare(`SELECT COUNT(*) AS c FROM messages_in`).get() as { c: number }).c;
    expect(count).toBe(1);
  });

  it('computes the next run on the owner’s stored timezone (09:00 there)', async () => {
    initTestDb();
    runMigrations(getDb());
    upsertPersonTz(getDb(), 'owner-london', 'Europe/London', new Date('2026-07-01T00:00:00Z').toISOString());
    try {
      const db = freshDb();
      insertTask(db, {
        id: 'task-tz',
        processAfter: '2020-01-01T00:00:00.000Z',
        recurrence: '0 9 * * *',
        platformId: null,
        channelType: null,
        threadId: null,
        content: JSON.stringify({ prompt: 'brief' }),
      });
      db.prepare(`UPDATE messages_in SET status='completed' WHERE id='task-tz'`).run();

      await handleRecurrence(db, { ...fakeSession(), owner_key: 'owner-london' } as Session);

      const follow = db.prepare(`SELECT process_after FROM messages_in WHERE id != 'task-tz'`).get() as {
        process_after: string;
      };
      // DST-proof: assert the wall-clock in Europe/London is exactly 09:00.
      const parts = new Intl.DateTimeFormat('en-GB', {
        timeZone: 'Europe/London',
        hour: '2-digit',
        minute: '2-digit',
        hour12: false,
      }).formatToParts(new Date(follow.process_after));
      const hour = parts.find((p) => p.type === 'hour')!.value;
      const minute = parts.find((p) => p.type === 'minute')!.value;
      expect(`${hour}:${minute}`).toBe('09:00');
    } finally {
      closeDb();
    }
  });

  it('resolves the owner’s tz when session.owner_key is null (empty owner → OWNER_PERSON_KEY)', async () => {
    // Real owner sessions carry owner_key = null; only named co-users (e.g. lena)
    // get an explicit key. person_tz is keyed on the canonical OWNER_PERSON_KEY
    // ('owner') — the same string the user-memory dir + iOS identity use. Passing
    // the raw null to resolveOwnerTz short-circuits to the host TIMEZONE, so a
    // travelling owner's brief fires on the home zone (early/late). Normalizing
    // null → OWNER_PERSON_KEY (the established `owner_key || OWNER_PERSON_KEY`
    // idiom) is what makes the feature actually reach the owner.
    initTestDb();
    runMigrations(getDb());
    upsertPersonTz(getDb(), OWNER_PERSON_KEY, 'Europe/London', new Date('2026-07-01T00:00:00Z').toISOString());
    try {
      const db = freshDb();
      insertTask(db, {
        id: 'task-owner-null',
        processAfter: '2020-01-01T00:00:00.000Z',
        recurrence: '0 9 * * *',
        platformId: null,
        channelType: null,
        threadId: null,
        content: JSON.stringify({ prompt: 'brief' }),
      });
      db.prepare(`UPDATE messages_in SET status='completed' WHERE id='task-owner-null'`).run();

      await handleRecurrence(db, { ...fakeSession(), owner_key: null } as Session);

      const follow = db.prepare(`SELECT process_after FROM messages_in WHERE id != 'task-owner-null'`).get() as {
        process_after: string;
      };
      // DST-proof: the wall-clock in Europe/London must be exactly 09:00.
      const parts = new Intl.DateTimeFormat('en-GB', {
        timeZone: 'Europe/London',
        hour: '2-digit',
        minute: '2-digit',
        hour12: false,
      }).formatToParts(new Date(follow.process_after));
      const hour = parts.find((p) => p.type === 'hour')!.value;
      const minute = parts.find((p) => p.type === 'minute')!.value;
      expect(`${hour}:${minute}`).toBe('09:00');
    } finally {
      closeDb();
    }
  });
});
