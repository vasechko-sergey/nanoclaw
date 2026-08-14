/**
 * Tests for src/modules/interactive/index.ts — the host-side handler for
 * ask_user_question button clicks.
 *
 * handleInteractiveResponse self-registers via registerResponseHandler() at
 * import time and is not itself exported, so tests reach it through
 * getResponseHandlers() — same indirection modules/permissions/sender-approval.test.ts
 * uses for its own self-registering handler.
 *
 * DB + writeSessionMessage are exercised for REAL (in-memory central DB via
 * initTestDb/runMigrations, a real on-disk session folder via
 * initSessionFolder), matching session-manager.test.ts and agent-route.test.ts.
 * Only wakeContainer is mocked — it is the sole call that would otherwise try
 * to spawn a real Docker container.
 */
import fs from 'fs';
import path from 'path';
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';

import {
  initTestDb,
  closeDb,
  runMigrations,
  createAgentGroup,
  createSession,
  createPendingQuestion,
} from '../../db/index.js';
import { initSessionFolder, openInboundDb, sessionsBaseDir } from '../../session-manager.js';
import { getResponseHandlers, type ResponsePayload } from '../../response-registry.js';

vi.mock('../../container-runner.js', () => ({
  wakeContainer: vi.fn().mockResolvedValue(undefined),
}));

function now(): string {
  return new Date().toISOString();
}

let TEST_AG: string;
const SESSION_ID = 'sess-interactive-test';

/** Mirrors how delivery.ts's onAction dispatches a click: first handler to claim it wins. */
async function handleClick(payload: ResponsePayload): Promise<boolean> {
  for (const handler of getResponseHandlers()) {
    if (await handler(payload)) return true;
  }
  return false;
}

function readSystemMessages(agentGroupId: string, sessionId: string) {
  const db = openInboundDb(agentGroupId, sessionId);
  const rows = db.prepare("SELECT content FROM messages_in WHERE kind = 'system' ORDER BY seq ASC").all() as Array<{
    content: string;
  }>;
  db.close();
  return rows;
}

beforeEach(async () => {
  TEST_AG = `test-interactive-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const db = initTestDb();
  runMigrations(db);

  // Side-effect import: registers handleInteractiveResponse into the
  // (process-wide) response-registry. Importing after runMigrations mirrors
  // sender-approval.test.ts; ordering doesn't actually matter here since
  // hasTable() is checked at call time, not import time, but this keeps the
  // two test files consistent for anyone reading both.
  await import('./index.js');

  createAgentGroup({ id: TEST_AG, name: 'Test Agent', folder: TEST_AG, agent_provider: null, created_at: now() });
  createSession({
    id: SESSION_ID,
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
  initSessionFolder(TEST_AG, SESSION_ID);
});

afterEach(() => {
  const dir = path.join(sessionsBaseDir(), TEST_AG);
  if (fs.existsSync(dir)) fs.rmSync(dir, { recursive: true, force: true });
  closeDb();
});

describe('handleInteractiveResponse', () => {
  it('carries the pending question title alongside questionId and selectedOption', async () => {
    createPendingQuestion({
      question_id: 'q-morning-1',
      session_id: SESSION_ID,
      message_out_id: 'mout-1',
      platform_id: 'chat-1',
      channel_type: 'telegram',
      thread_id: null,
      title: 'Как проснулся?',
      options: [{ label: 'Ок', selectedLabel: 'Ок', value: 'ok' }],
      created_at: now(),
    });

    const claimed = await handleClick({
      questionId: 'q-morning-1',
      value: 'ok',
      userId: 'telegram:owner',
      channelType: 'telegram',
      platformId: 'chat-1',
      threadId: null,
    });
    expect(claimed).toBe(true);

    const rows = readSystemMessages(TEST_AG, SESSION_ID);
    expect(rows).toHaveLength(1);
    const content = JSON.parse(rows[0].content);
    expect(content).toMatchObject({
      type: 'question_response',
      questionId: 'q-morning-1',
      selectedOption: 'ok',
      title: 'Как проснулся?',
    });
  });

  it('a click with no matching pending question is not claimed and writes nothing', async () => {
    const claimed = await handleClick({
      questionId: 'q-does-not-exist',
      value: 'ok',
      userId: 'telegram:owner',
      channelType: 'telegram',
      platformId: 'chat-1',
      threadId: null,
    });
    expect(claimed).toBe(false);
    expect(readSystemMessages(TEST_AG, SESSION_ID)).toHaveLength(0);
  });
});
