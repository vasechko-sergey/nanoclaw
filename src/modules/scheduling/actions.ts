/**
 * Delivery action handlers for scheduling.
 *
 * The container can't write to inbound.db (host-owned). When the agent calls
 * schedule_task / cancel_task / etc. via MCP, the container writes a
 * `kind='system'` outbound message with an `action` field. The delivery path
 * reaches into this module via the delivery-action registry and we apply the
 * change to inbound.db here.
 */
import type Database from 'better-sqlite3';

import { wakeContainer } from '../../container-runner.js';
import { findActiveHeadlessSession, getSession } from '../../db/sessions.js';
import { log } from '../../log.js';
import { openInboundDb, resolveHeadlessSession, writeSessionMessage } from '../../session-manager.js';
import type { Session } from '../../types.js';
import { cancelTask, insertTask, pauseTask, resumeTask, updateTask, type TaskUpdate } from './db.js';

/**
 * Apply a task mutation to the emitting session's inbound.db; if it touched
 * nothing AND we're in an interactive session, retry against the owner's
 * headless session — that's where recurring tasks are consolidated (see
 * handleScheduleTask). Without this, cancel/pause/resume/update of a recurring
 * task from a chat session silently no-ops: the row lives in headless, not in
 * the session that emitted the action. Returns total rows touched.
 */
function applyToTaskHome(session: Session, inDb: Database.Database, fn: (db: Database.Database) => number): number {
  const touched = fn(inDb);
  if (touched > 0 || session.messaging_group_id == null) return touched;

  const headless = findActiveHeadlessSession(session.agent_group_id, session.owner_key);
  if (!headless || headless.id === session.id) return touched;

  const headlessDb = openInboundDb(session.agent_group_id, headless.id);
  try {
    return fn(headlessDb);
  } finally {
    headlessDb.close();
  }
}

export async function handleScheduleTask(
  content: Record<string, unknown>,
  session: Session,
  inDb: Database.Database,
): Promise<void> {
  const taskId = content.taskId as string;
  const prompt = content.prompt as string;
  const script = content.script as string | null;
  const processAfter = content.processAfter as string;
  const recurrence = (content.recurrence as string) || null;

  const task = {
    id: taskId,
    processAfter,
    recurrence,
    platformId: (content.platformId as string) ?? null,
    channelType: (content.channelType as string) ?? null,
    threadId: (content.threadId as string) ?? null,
    content: JSON.stringify({ prompt, script }),
  };

  // Recurring tasks scheduled from an INTERACTIVE session must land in the
  // agent's headless session — host-sweep fans recurrence per active session,
  // and an interactive session keeps its SDK continuation, so cron would
  // resume the live chat (context bleed). Headless wipes continuation each
  // fire. One-shot tasks stay in the emitting session (conversational
  // follow-ups that reply in-thread). If we're already headless, no redirect.
  if (recurrence && session.messaging_group_id != null) {
    const headless = resolveHeadlessSession(session.agent_group_id, session.owner_key);
    const headlessDb = openInboundDb(session.agent_group_id, headless.id);
    try {
      insertTask(headlessDb, task);
    } finally {
      headlessDb.close();
    }
    log.info('Scheduled recurring task routed to headless session', {
      taskId,
      from: session.id,
      headlessId: headless.id,
      processAfter,
      recurrence,
    });
    return;
  }

  insertTask(inDb, task);
  log.info('Scheduled task created', { taskId, processAfter, recurrence });
}

export async function handleCancelTask(
  content: Record<string, unknown>,
  session: Session,
  inDb: Database.Database,
): Promise<void> {
  const taskId = content.taskId as string;
  const touched = applyToTaskHome(session, inDb, (db) => cancelTask(db, taskId));
  log.info('Task cancelled', { taskId, touched });
}

export async function handlePauseTask(
  content: Record<string, unknown>,
  session: Session,
  inDb: Database.Database,
): Promise<void> {
  const taskId = content.taskId as string;
  const touched = applyToTaskHome(session, inDb, (db) => pauseTask(db, taskId));
  log.info('Task paused', { taskId, touched });
}

export async function handleResumeTask(
  content: Record<string, unknown>,
  session: Session,
  inDb: Database.Database,
): Promise<void> {
  const taskId = content.taskId as string;
  const touched = applyToTaskHome(session, inDb, (db) => resumeTask(db, taskId));
  log.info('Task resumed', { taskId, touched });
}

export async function handleUpdateTask(
  content: Record<string, unknown>,
  session: Session,
  inDb: Database.Database,
): Promise<void> {
  const taskId = content.taskId as string;
  const update: TaskUpdate = {};
  if (typeof content.prompt === 'string') update.prompt = content.prompt;
  if (typeof content.processAfter === 'string') update.processAfter = content.processAfter;
  if (content.recurrence === null || typeof content.recurrence === 'string') {
    update.recurrence = content.recurrence as string | null;
  }
  if (content.script === null || typeof content.script === 'string') {
    update.script = content.script as string | null;
  }
  const touched = applyToTaskHome(session, inDb, (db) => updateTask(db, taskId, update));
  log.info('Task updated', { taskId, touched, fields: Object.keys(update) });
  if (touched === 0) {
    // Notify the agent that update_task matched nothing. Replicates the
    // old notifyAgent helper that used to live in delivery.ts — inlined
    // here so scheduling doesn't depend on delivery's private helpers.
    writeSessionMessage(session.agent_group_id, session.id, {
      id: `sys-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
      kind: 'chat',
      timestamp: new Date().toISOString(),
      platformId: session.agent_group_id,
      channelType: 'agent',
      threadId: null,
      content: JSON.stringify({
        text: `update_task: no live task matched id "${taskId}".`,
        sender: 'system',
        senderId: 'system',
      }),
    });
    const fresh = getSession(session.id);
    if (fresh) {
      wakeContainer(fresh).catch((err) =>
        log.error('Failed to wake container after update_task notification', { err }),
      );
    }
  }
}
