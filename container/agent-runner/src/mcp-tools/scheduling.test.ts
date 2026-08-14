/**
 * list_tasks must union the current session's tasks with the owner's headless
 * session (mounted read-only at /workspace/.headless). Recurring tasks are
 * consolidated into headless by the host, so a list that only reads the
 * current session reports "empty" and the agent re-creates the cron.
 */
import { afterEach, describe, expect, it } from 'bun:test';
import { Database } from 'bun:sqlite';

import { closeSessionDb, initTestHeadlessInboundDb, initTestSessionDb } from '../db/connection.js';
import { TIMEZONE, parseZonedToUtc } from '../timezone.js';
import { listTasks, scheduleTask, updateTask } from './scheduling.js';

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

/**
 * A naive `processAfter` means the OWNER's wall clock, not the container's.
 * The container's own TZ is the global host zone; the owner's device zone
 * arrives separately as OWNER_TZ, and that is the zone the host's recurrence
 * sweep uses (src/modules/scheduling/recurrence.ts). Converting the first run
 * against TZ while every repeat fires on OWNER_TZ puts the first run in the
 * wrong place — observed 2026-08-14, a 21:00 Asia/Colombo task landing at
 * 13:00Z (21:00 at UTC+8) instead of 15:30Z.
 */
describe('processAfter is interpreted in OWNER_TZ', () => {
  const savedOwnerTz = process.env.OWNER_TZ;

  afterEach(() => {
    if (savedOwnerTz === undefined) delete process.env.OWNER_TZ;
    else process.env.OWNER_TZ = savedOwnerTz;
    closeSessionDb();
  });

  /** Run one tool call under `ownerTz` and return the processAfter it emitted. */
  async function emittedProcessAfter(
    tool: typeof scheduleTask,
    args: Record<string, unknown>,
    ownerTz: string | undefined,
  ): Promise<string> {
    if (ownerTz === undefined) delete process.env.OWNER_TZ;
    else process.env.OWNER_TZ = ownerTz;
    const { outbound } = initTestSessionDb();
    try {
      await tool.handler(args);
      const row = outbound
        .prepare(`SELECT content FROM messages_out WHERE kind = 'system' ORDER BY seq DESC LIMIT 1`)
        .get() as { content: string };
      return JSON.parse(row.content).processAfter as string;
    } finally {
      closeSessionDb();
    }
  }

  it('schedule_task converts against OWNER_TZ, not the container TZ', async () => {
    const args = { prompt: 'evening check-in', processAfter: '2026-08-14T21:00:00' };

    // 21:00 in Colombo (UTC+5:30) is 15:30Z; the same wall clock in Kiritimati
    // (UTC+14) is 07:00Z. Two zones, so the assertion holds whatever the test
    // machine's own TZ happens to be.
    expect(await emittedProcessAfter(scheduleTask, args, 'Asia/Colombo')).toBe('2026-08-14T15:30:00.000Z');
    expect(await emittedProcessAfter(scheduleTask, args, 'Pacific/Kiritimati')).toBe('2026-08-14T07:00:00.000Z');
  });

  it('update_task converts against OWNER_TZ, not the container TZ', async () => {
    const args = { taskId: 'task-1', processAfter: '2026-08-14T21:00:00' };

    expect(await emittedProcessAfter(updateTask, args, 'Asia/Colombo')).toBe('2026-08-14T15:30:00.000Z');
    expect(await emittedProcessAfter(updateTask, args, 'Pacific/Kiritimati')).toBe('2026-08-14T07:00:00.000Z');
  });

  it('falls back to the container TZ when OWNER_TZ is unset', async () => {
    const naive = '2026-08-14T21:00:00';
    const emitted = await emittedProcessAfter(scheduleTask, { prompt: 'p', processAfter: naive }, undefined);

    expect(emitted).toBe(parseZonedToUtc(naive, TIMEZONE).toISOString());
  });

  it('ignores a garbage OWNER_TZ and falls back to the container TZ', async () => {
    const naive = '2026-08-14T21:00:00';
    const emitted = await emittedProcessAfter(scheduleTask, { prompt: 'p', processAfter: naive }, 'NotATimezone');

    expect(emitted).toBe(parseZonedToUtc(naive, TIMEZONE).toISOString());
  });
});
