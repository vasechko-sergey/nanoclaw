/**
 * Tests for scheduling delivery-action routing.
 *
 * Focus: a RECURRING task scheduled from an INTERACTIVE session must be routed
 * to the agent's headless session (messaging_group_id IS NULL) so cron never
 * resumes a live chat continuation (context bleed). One-shot tasks stay in the
 * emitting session.
 *
 * DATA_DIR is frozen at module load under <repo>/data, so each test uses a
 * unique throwaway agent-group id and removes only its own session subtree.
 */
import fs from 'fs';
import path from 'path';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';

import {
  initTestDb,
  closeDb,
  runMigrations,
  createAgentGroup,
  createSession,
  createMessagingGroup,
} from '../../db/index.js';
import { getSessionsByAgentGroup } from '../../db/sessions.js';
import { initSessionFolder, openInboundDb, sessionsBaseDir } from '../../session-manager.js';
import type { Session } from '../../types.js';
import { handleScheduleTask, handleCancelTask, handleUpdateTask } from './actions.js';

function now() {
  return new Date().toISOString();
}

let TEST_AG: string;
const INTERACTIVE_SESSION = 'sess-interactive-test';

function countTasks(agentGroupId: string, sessionId: string): number {
  const db = openInboundDb(agentGroupId, sessionId);
  try {
    return (db.prepare("SELECT COUNT(*) AS n FROM messages_in WHERE kind = 'task'").get() as { n: number }).n;
  } finally {
    db.close();
  }
}

function countLiveTasks(agentGroupId: string, sessionId: string): number {
  const db = openInboundDb(agentGroupId, sessionId);
  try {
    return (
      db
        .prepare("SELECT COUNT(*) AS n FROM messages_in WHERE kind = 'task' AND status IN ('pending', 'paused')")
        .get() as { n: number }
    ).n;
  } finally {
    db.close();
  }
}

function taskRecurrence(agentGroupId: string, sessionId: string, taskId: string): string | null {
  const db = openInboundDb(agentGroupId, sessionId);
  try {
    const row = db
      .prepare("SELECT recurrence FROM messages_in WHERE series_id = ? AND status IN ('pending', 'paused')")
      .get(taskId) as { recurrence: string | null } | undefined;
    return row ? row.recurrence : null;
  } finally {
    db.close();
  }
}

function onlyHeadless(): Session {
  const h = getSessionsByAgentGroup(TEST_AG).filter((s) => s.messaging_group_id === null && s.status === 'active');
  if (h.length !== 1) throw new Error(`expected exactly 1 headless session, got ${h.length}`);
  return h[0];
}

function interactiveSession(): Session {
  return {
    id: INTERACTIVE_SESSION,
    agent_group_id: TEST_AG,
    messaging_group_id: 'mg-test-interactive',
    thread_id: null,
    owner_key: null,
    agent_provider: null,
    status: 'active',
    container_status: 'stopped',
    last_active: null,
    created_at: now(),
  };
}

function scheduleContent(recurrence: string | null) {
  return {
    action: 'schedule_task',
    taskId: `task-test-${Math.random().toString(36).slice(2, 8)}`,
    prompt: 'Load the `publish` skill and run it now',
    script: null,
    processAfter: '2026-06-18T00:45:00.000Z',
    recurrence,
    platformId: null,
    channelType: null,
    threadId: null,
  } as Record<string, unknown>;
}

beforeEach(() => {
  TEST_AG = `test-sched-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const db = initTestDb();
  runMigrations(db);
  createAgentGroup({ id: TEST_AG, name: 'Test', folder: TEST_AG, agent_provider: null, created_at: now() });
  createMessagingGroup({
    id: 'mg-test-interactive',
    channel_type: 'test',
    platform_id: 'plat-test',
    name: 'Test Interactive',
    is_group: 0,
    unknown_sender_policy: 'strict',
    created_at: now(),
  });
  createSession(interactiveSession());
  initSessionFolder(TEST_AG, INTERACTIVE_SESSION);
});

afterEach(() => {
  const dir = path.join(sessionsBaseDir(), TEST_AG);
  if (fs.existsSync(dir)) fs.rmSync(dir, { recursive: true, force: true });
  closeDb();
});

describe('handleScheduleTask routing', () => {
  it('routes a RECURRING task to a headless session, not the emitting interactive session', async () => {
    const session = interactiveSession();
    const inDb = openInboundDb(TEST_AG, INTERACTIVE_SESSION);
    try {
      await handleScheduleTask(scheduleContent('45 8 * * *'), session, inDb);
    } finally {
      inDb.close();
    }

    // A headless session (messaging_group_id IS NULL) was created for the agent.
    const headless = getSessionsByAgentGroup(TEST_AG).filter(
      (s) => s.messaging_group_id === null && s.status === 'active',
    );
    expect(headless).toHaveLength(1);

    // The recurring task lives in the headless session...
    expect(countTasks(TEST_AG, headless[0].id)).toBe(1);
    // ...and NOT in the emitting interactive session.
    expect(countTasks(TEST_AG, INTERACTIVE_SESSION)).toBe(0);
  });

  it('keeps a ONE-SHOT task in the emitting interactive session', async () => {
    const session = interactiveSession();
    const inDb = openInboundDb(TEST_AG, INTERACTIVE_SESSION);
    try {
      await handleScheduleTask(scheduleContent(null), session, inDb);
    } finally {
      inDb.close();
    }

    expect(countTasks(TEST_AG, INTERACTIVE_SESSION)).toBe(1);
    // No headless session spun up for a one-shot.
    const headless = getSessionsByAgentGroup(TEST_AG).filter((s) => s.messaging_group_id === null);
    expect(headless).toHaveLength(0);
  });

  it('inserts directly when the emitting session is already headless', async () => {
    const headlessId = 'sess-already-headless';
    createSession({
      id: headlessId,
      agent_group_id: TEST_AG,
      messaging_group_id: null,
      thread_id: null,
      owner_key: null,
      agent_provider: null,
      status: 'active',
      container_status: 'stopped',
      last_active: null,
      created_at: now(),
    });
    initSessionFolder(TEST_AG, headlessId);

    const session: Session = { ...interactiveSession(), id: headlessId, messaging_group_id: null };
    const inDb = openInboundDb(TEST_AG, headlessId);
    try {
      await handleScheduleTask(scheduleContent('45 8 * * *'), session, inDb);
    } finally {
      inDb.close();
    }

    // Task stays in the headless session; no second headless session created.
    expect(countTasks(TEST_AG, headlessId)).toBe(1);
    const headless = getSessionsByAgentGroup(TEST_AG).filter((s) => s.messaging_group_id === null);
    expect(headless).toHaveLength(1);
  });
});

// Recurring tasks live in the headless session, but cancel/pause/resume/update
// arrive from an INTERACTIVE session. They must fall back to the headless
// session's inbound.db, or the mutation silently no-ops (the live bug: agent
// "cancels" a cron that keeps firing).
describe('task mutations fall back to the headless session', () => {
  async function scheduleRecurringFromInteractive(): Promise<string> {
    const content = scheduleContent('45 8 * * *');
    const inDb = openInboundDb(TEST_AG, INTERACTIVE_SESSION);
    try {
      await handleScheduleTask(content, interactiveSession(), inDb);
    } finally {
      inDb.close();
    }
    return content.taskId as string;
  }

  it('handleCancelTask cancels a recurring task that lives in headless', async () => {
    const taskId = await scheduleRecurringFromInteractive();
    const headless = onlyHeadless();
    expect(countLiveTasks(TEST_AG, headless.id)).toBe(1);

    const inDb = openInboundDb(TEST_AG, INTERACTIVE_SESSION);
    try {
      await handleCancelTask({ action: 'cancel_task', taskId }, interactiveSession(), inDb);
    } finally {
      inDb.close();
    }

    // The cron is actually gone from headless, not just from the (empty) interactive db.
    expect(countLiveTasks(TEST_AG, headless.id)).toBe(0);
  });

  it('handleUpdateTask edits a recurring task that lives in headless', async () => {
    const taskId = await scheduleRecurringFromInteractive();
    const headless = onlyHeadless();
    expect(taskRecurrence(TEST_AG, headless.id, taskId)).toBe('45 8 * * *');

    const inDb = openInboundDb(TEST_AG, INTERACTIVE_SESSION);
    try {
      await handleUpdateTask({ action: 'update_task', taskId, recurrence: '0 9 * * *' }, interactiveSession(), inDb);
    } finally {
      inDb.close();
    }

    expect(taskRecurrence(TEST_AG, headless.id, taskId)).toBe('0 9 * * *');
  });

  it('handleCancelTask still cancels a ONE-SHOT in the emitting interactive session', async () => {
    const content = scheduleContent(null);
    const taskId = content.taskId as string;
    let inDb = openInboundDb(TEST_AG, INTERACTIVE_SESSION);
    try {
      await handleScheduleTask(content, interactiveSession(), inDb);
    } finally {
      inDb.close();
    }
    expect(countLiveTasks(TEST_AG, INTERACTIVE_SESSION)).toBe(1);

    inDb = openInboundDb(TEST_AG, INTERACTIVE_SESSION);
    try {
      await handleCancelTask({ action: 'cancel_task', taskId }, interactiveSession(), inDb);
    } finally {
      inDb.close();
    }
    expect(countLiveTasks(TEST_AG, INTERACTIVE_SESSION)).toBe(0);
    // No headless session was spun up for a one-shot mutation.
    expect(getSessionsByAgentGroup(TEST_AG).filter((s) => s.messaging_group_id === null)).toHaveLength(0);
  });
});
