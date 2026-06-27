/**
 * list_tasks must union the current session's tasks with the owner's headless
 * session (mounted read-only at /workspace/.headless). Recurring tasks are
 * consolidated into headless by the host, so a list that only reads the
 * current session reports "empty" and the agent re-creates the cron.
 */
import { afterEach, describe, expect, it } from 'bun:test';
import { Database } from 'bun:sqlite';

import { closeSessionDb, initTestHeadlessInboundDb, initTestSessionDb } from '../db/connection.js';
import { listTasks } from './scheduling.js';

function insertTask(
  db: Database,
  t: { id: string; recurrence: string | null; processAfter: string; prompt: string; seq: number },
): void {
  db.prepare(
    `INSERT INTO messages_in (id, seq, kind, timestamp, status, process_after, recurrence, series_id, content)
     VALUES ($id, $seq, 'task', datetime('now'), 'pending', $pa, $rec, $id, $content)`,
  ).run({ $id: t.id, $seq: t.seq, $pa: t.processAfter, $rec: t.recurrence, $content: JSON.stringify({ prompt: t.prompt }) });
}

describe('list_tasks unions the headless session', () => {
  afterEach(() => closeSessionDb());

  it('includes recurring tasks that live in the mounted headless session', async () => {
    const { inbound } = initTestSessionDb();
    const headless = initTestHeadlessInboundDb();
    insertTask(inbound, { id: 'task-oneshot', recurrence: null, processAfter: '2026-06-27T10:00:00.000Z', prompt: 'one shot reminder', seq: 2 });
    insertTask(headless, { id: 'task-cron', recurrence: '0 9 * * *', processAfter: '2026-06-28T01:00:00.000Z', prompt: 'morning brief', seq: 2 });

    const res = await listTasks.handler({});
    const text = (res.content[0] as { text: string }).text;

    expect(text).toContain('task-oneshot');
    expect(text).toContain('task-cron');
    expect(text).toContain('recur=0 9 * * *');
  });

  it('sorts the unioned tasks by next run time', async () => {
    const { inbound } = initTestSessionDb();
    const headless = initTestHeadlessInboundDb();
    insertTask(inbound, { id: 'task-later', recurrence: null, processAfter: '2026-06-29T10:00:00.000Z', prompt: 'later', seq: 2 });
    insertTask(headless, { id: 'task-sooner', recurrence: '0 9 * * *', processAfter: '2026-06-28T01:00:00.000Z', prompt: 'sooner', seq: 2 });

    const res = await listTasks.handler({});
    const text = (res.content[0] as { text: string }).text;

    expect(text.indexOf('task-sooner')).toBeLessThan(text.indexOf('task-later'));
  });

  it('returns only this session tasks when no headless db is mounted', async () => {
    const { inbound } = initTestSessionDb();
    insertTask(inbound, { id: 'task-local', recurrence: null, processAfter: '2026-06-27T10:00:00.000Z', prompt: 'local only', seq: 2 });

    const res = await listTasks.handler({});
    const text = (res.content[0] as { text: string }).text;

    expect(text).toContain('task-local');
  });

  it('reports no tasks when both sessions are empty', async () => {
    initTestSessionDb();
    initTestHeadlessInboundDb();

    const res = await listTasks.handler({});
    const text = (res.content[0] as { text: string }).text;

    expect(text).toContain('No tasks found.');
  });
});
