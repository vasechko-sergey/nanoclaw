/**
 * Tests for the scheduling module's task DB helpers — focused on the
 * series_id invariant that lets cancel/pause/resume/update reach the live
 * next occurrence of a recurring task, even after the row the agent
 * remembers has completed and been replaced by a follow-up.
 */
import fs from 'fs';
import path from 'path';
import { describe, it, expect, afterEach } from 'vitest';

import { ensureSchema, openInboundDb } from '../../db/session-db.js';
import {
  insertTask,
  insertRecurrence,
  cancelTask,
  pauseTask,
  resumeTask,
  updateTask,
  getCompletedRecurring,
  migrateRecurringTasks,
  type RecurringMessage,
} from './db.js';

const TEST_DIR = '/tmp/nanoclaw-scheduling-db-test';
const DB_PATH = path.join(TEST_DIR, 'inbound.db');

function freshDb() {
  if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true });
  fs.mkdirSync(TEST_DIR, { recursive: true });
  ensureSchema(DB_PATH, 'inbound');
  return openInboundDb(DB_PATH);
}

function insertBasicTask(db: ReturnType<typeof openInboundDb>, id: string, recurrence: string | null) {
  insertTask(db, {
    id,
    processAfter: new Date().toISOString(),
    recurrence,
    platformId: null,
    channelType: null,
    threadId: null,
    content: JSON.stringify({ prompt: 'noop' }),
  });
}

afterEach(() => {
  if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true });
});

describe('insertTask', () => {
  it('stamps series_id = id on insert', () => {
    const db = freshDb();
    insertBasicTask(db, 'task-1', null);
    const row = db.prepare('SELECT series_id FROM messages_in WHERE id = ?').get('task-1') as { series_id: string };
    expect(row.series_id).toBe('task-1');
    db.close();
  });
});

describe('cancelTask / pauseTask / resumeTask series matching', () => {
  // Simulates the recurrence chain that used to survive cancellation:
  // the original task completes → handleRecurrence spawns a follow-up
  // row → agent calls cancel_task(originalId) → historically only hit
  // the completed row, leaving the live one running.
  function seedRecurringChain(db: ReturnType<typeof openInboundDb>) {
    insertBasicTask(db, 'task-orig', '0 9 * * *');
    // Mark the original as completed (as syncProcessingAcks would do).
    db.prepare("UPDATE messages_in SET status = 'completed' WHERE id = 'task-orig'").run();

    const msg: RecurringMessage = {
      id: 'task-orig',
      kind: 'task',
      content: JSON.stringify({ prompt: 'noop' }),
      recurrence: '0 9 * * *',
      process_after: null,
      platform_id: null,
      channel_type: null,
      thread_id: null,
      series_id: 'task-orig',
    };
    insertRecurrence(db, msg, 'task-next', new Date(Date.now() + 86400000).toISOString());
  }

  it('cancel by original id reaches the live follow-up via series_id', () => {
    const db = freshDb();
    seedRecurringChain(db);

    cancelTask(db, 'task-orig');

    const live = db.prepare("SELECT id, status, recurrence FROM messages_in WHERE status = 'pending'").all();
    expect(live).toHaveLength(0);

    const followUp = db.prepare("SELECT status, recurrence FROM messages_in WHERE id = 'task-next'").get() as {
      status: string;
      recurrence: string | null;
    };
    expect(followUp.status).toBe('completed');
    // Recurrence cleared so the sweep doesn't spawn another clone.
    expect(followUp.recurrence).toBeNull();
    db.close();
  });

  it('cancelled task is not picked up by getCompletedRecurring', () => {
    const db = freshDb();
    insertBasicTask(db, 'task-1', '0 9 * * *');
    cancelTask(db, 'task-1');

    const recurring = getCompletedRecurring(db);
    expect(recurring).toHaveLength(0);
    db.close();
  });

  it('pause by original id pauses the live follow-up', () => {
    const db = freshDb();
    seedRecurringChain(db);

    pauseTask(db, 'task-orig');

    const followUp = db.prepare("SELECT status FROM messages_in WHERE id = 'task-next'").get() as { status: string };
    expect(followUp.status).toBe('paused');
    db.close();
  });

  it('resume by original id resumes the live follow-up', () => {
    const db = freshDb();
    seedRecurringChain(db);

    db.prepare("UPDATE messages_in SET status = 'paused' WHERE id = 'task-next'").run();
    resumeTask(db, 'task-orig');

    const followUp = db.prepare("SELECT status FROM messages_in WHERE id = 'task-next'").get() as { status: string };
    expect(followUp.status).toBe('pending');
    db.close();
  });
});

describe('updateTask', () => {
  it('merges supplied fields into content JSON without clobbering others', () => {
    const db = freshDb();
    insertTask(db, {
      id: 'task-1',
      processAfter: new Date().toISOString(),
      recurrence: null,
      platformId: null,
      channelType: null,
      threadId: null,
      content: JSON.stringify({ prompt: 'old', script: 'echo old', extra: 'keep me' }),
    });

    const touched = updateTask(db, 'task-1', { prompt: 'new' });
    expect(touched).toBe(1);

    const row = db.prepare('SELECT content FROM messages_in WHERE id = ?').get('task-1') as { content: string };
    const parsed = JSON.parse(row.content);
    expect(parsed.prompt).toBe('new');
    expect(parsed.script).toBe('echo old');
    expect(parsed.extra).toBe('keep me');
  });

  it('updates recurrence and process_after when supplied', () => {
    const db = freshDb();
    insertTask(db, {
      id: 'task-1',
      processAfter: '2026-01-01T00:00:00Z',
      recurrence: '0 9 * * *',
      platformId: null,
      channelType: null,
      threadId: null,
      content: JSON.stringify({ prompt: 'p' }),
    });

    updateTask(db, 'task-1', { recurrence: '0 18 * * *', processAfter: '2026-02-01T00:00:00Z' });

    const row = db.prepare('SELECT recurrence, process_after FROM messages_in WHERE id = ?').get('task-1') as {
      recurrence: string;
      process_after: string;
    };
    expect(row.recurrence).toBe('0 18 * * *');
    expect(row.process_after).toBe('2026-02-01T00:00:00Z');
  });

  it('clears recurrence when null is passed', () => {
    const db = freshDb();
    insertTask(db, {
      id: 'task-1',
      processAfter: '2026-01-01T00:00:00Z',
      recurrence: '0 9 * * *',
      platformId: null,
      channelType: null,
      threadId: null,
      content: JSON.stringify({ prompt: 'p' }),
    });

    updateTask(db, 'task-1', { recurrence: null });

    const row = db.prepare('SELECT recurrence FROM messages_in WHERE id = ?').get('task-1') as {
      recurrence: string | null;
    };
    expect(row.recurrence).toBeNull();
  });

  it('reaches the live follow-up via series_id when called with the original id', () => {
    const db = freshDb();
    insertTask(db, {
      id: 'task-orig',
      processAfter: new Date().toISOString(),
      recurrence: '0 9 * * *',
      platformId: null,
      channelType: null,
      threadId: null,
      content: JSON.stringify({ prompt: 'old' }),
    });
    db.prepare("UPDATE messages_in SET status = 'completed' WHERE id = 'task-orig'").run();

    const msg: RecurringMessage = {
      id: 'task-orig',
      kind: 'task',
      content: JSON.stringify({ prompt: 'old' }),
      recurrence: '0 9 * * *',
      process_after: null,
      platform_id: null,
      channel_type: null,
      thread_id: null,
      series_id: 'task-orig',
    };
    insertRecurrence(db, msg, 'task-next', new Date(Date.now() + 86400000).toISOString());

    const touched = updateTask(db, 'task-orig', { prompt: 'new' });
    // Only the live follow-up should be touched — completed rows are excluded.
    expect(touched).toBe(1);

    const live = db.prepare("SELECT content FROM messages_in WHERE id = 'task-next'").get() as { content: string };
    expect(JSON.parse(live.content).prompt).toBe('new');

    // Original (completed) row left alone.
    const orig = db.prepare("SELECT content FROM messages_in WHERE id = 'task-orig'").get() as { content: string };
    expect(JSON.parse(orig.content).prompt).toBe('old');
  });

  it('returns 0 when no live task matches', () => {
    const db = freshDb();
    insertTask(db, {
      id: 'task-1',
      processAfter: new Date().toISOString(),
      recurrence: null,
      platformId: null,
      channelType: null,
      threadId: null,
      content: JSON.stringify({ prompt: 'p' }),
    });
    db.prepare("UPDATE messages_in SET status = 'completed' WHERE id = 'task-1'").run();

    const touched = updateTask(db, 'task-1', { prompt: 'new' });
    expect(touched).toBe(0);
  });
});

describe('insertRecurrence', () => {
  it('copies series_id forward', () => {
    const db = freshDb();
    insertBasicTask(db, 'task-orig', '0 9 * * *');
    db.prepare("UPDATE messages_in SET status = 'completed' WHERE id = 'task-orig'").run();

    const msg: RecurringMessage = {
      id: 'task-orig',
      kind: 'task',
      content: '{}',
      recurrence: '0 9 * * *',
      process_after: null,
      platform_id: null,
      channel_type: null,
      thread_id: null,
      series_id: 'task-orig',
    };
    insertRecurrence(db, msg, 'task-next', new Date().toISOString());

    const row = db.prepare('SELECT series_id FROM messages_in WHERE id = ?').get('task-next') as {
      series_id: string;
    };
    expect(row.series_id).toBe('task-orig');
    db.close();
  });
});

describe('migrateRecurringTasks', () => {
  const TEST_DIR_TO = '/tmp/nanoclaw-scheduling-db-test-to';
  const DB_PATH_TO = path.join(TEST_DIR_TO, 'inbound.db');

  function freshToDb() {
    if (fs.existsSync(TEST_DIR_TO)) fs.rmSync(TEST_DIR_TO, { recursive: true });
    fs.mkdirSync(TEST_DIR_TO, { recursive: true });
    ensureSchema(DB_PATH_TO, 'inbound');
    return openInboundDb(DB_PATH_TO);
  }

  afterEach(() => {
    if (fs.existsSync(TEST_DIR_TO)) fs.rmSync(TEST_DIR_TO, { recursive: true });
  });

  it('migrates only live recurring tasks (returns count)', () => {
    const from = freshDb();
    const to = freshToDb();

    // Live recurring task — should be migrated
    insertBasicTask(from, 'task-recurring', '0 9 * * *');
    // Non-recurring task — should NOT be migrated
    insertBasicTask(from, 'task-oneshot', null);
    // Already-completed recurring row — should NOT be migrated
    insertBasicTask(from, 'task-done', '0 18 * * *');
    from.prepare("UPDATE messages_in SET status = 'completed' WHERE id = 'task-done'").run();

    const count = migrateRecurringTasks(from, to);
    expect(count).toBe(1);

    from.close();
    to.close();
  });

  it('destination has the migrated recurring task with same recurrence and content', () => {
    const from = freshDb();
    const to = freshToDb();

    const content = JSON.stringify({ prompt: 'morning brief', script: null });
    insertTask(from, {
      id: 'task-r',
      processAfter: '2026-06-15T09:00:00Z',
      recurrence: '0 9 * * *',
      platformId: 'plat-1',
      channelType: 'telegram',
      threadId: 'thr-1',
      content,
    });

    migrateRecurringTasks(from, to);

    const rows = to
      .prepare(
        "SELECT recurrence, content, platform_id, channel_type, thread_id FROM messages_in WHERE kind = 'task' AND recurrence IS NOT NULL AND status IN ('pending', 'paused')",
      )
      .all() as Array<{
      recurrence: string;
      content: string;
      platform_id: string | null;
      channel_type: string | null;
      thread_id: string | null;
    }>;
    expect(rows).toHaveLength(1);
    expect(rows[0].recurrence).toBe('0 9 * * *');
    expect(rows[0].content).toBe(content);
    expect(rows[0].platform_id).toBe('plat-1');
    expect(rows[0].channel_type).toBe('telegram');
    expect(rows[0].thread_id).toBe('thr-1');

    from.close();
    to.close();
  });

  it('cancels the source live recurring task after migration', () => {
    const from = freshDb();
    const to = freshToDb();

    insertBasicTask(from, 'task-recurring', '0 9 * * *');
    // Also insert a paused recurring task to cover that status
    insertBasicTask(from, 'task-paused', '0 18 * * *');
    from.prepare("UPDATE messages_in SET status = 'paused' WHERE id = 'task-paused'").run();

    migrateRecurringTasks(from, to);

    const srcRows = from
      .prepare(
        "SELECT id, status, recurrence FROM messages_in WHERE kind = 'task' AND id IN ('task-recurring', 'task-paused')",
      )
      .all() as Array<{ id: string; status: string; recurrence: string | null }>;

    for (const row of srcRows) {
      expect(row.status).toBe('completed');
      expect(row.recurrence).toBeNull();
    }

    from.close();
    to.close();
  });

  it('does not touch non-recurring tasks in the source', () => {
    const from = freshDb();
    const to = freshToDb();

    insertBasicTask(from, 'task-oneshot', null);
    insertBasicTask(from, 'task-recurring', '0 9 * * *');

    migrateRecurringTasks(from, to);

    const oneshot = from.prepare("SELECT status FROM messages_in WHERE id = 'task-oneshot'").get() as {
      status: string;
    };
    expect(oneshot.status).toBe('pending');

    from.close();
    to.close();
  });

  it('returns 0 and does not throw when source has no recurring tasks', () => {
    const from = freshDb();
    const to = freshToDb();

    const count = migrateRecurringTasks(from, to);
    expect(count).toBe(0);

    const toRows = to.prepare('SELECT * FROM messages_in').all();
    expect(toRows).toHaveLength(0);

    from.close();
    to.close();
  });
});
