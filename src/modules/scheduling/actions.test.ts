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

import { initTestDb, closeDb, runMigrations, createAgentGroup, createSession, createMessagingGroup } from '../../db/index.js';
import { getSessionsByAgentGroup } from '../../db/sessions.js';
import { initSessionFolder, openInboundDb, sessionsBaseDir } from '../../session-manager.js';
import type { Session } from '../../types.js';
import { handleScheduleTask } from './actions.js';

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
