import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import path from 'path';
import os from 'os';
import fs from 'fs';

import { initTestDb, closeDb, createAgentGroup, createMessagingGroup } from './db/index.js';
import { runMigrations } from './db/migrations/index.js';
import { findSessionForAgent } from './db/sessions.js';
import { adapterRouteToAgent } from './adapter-route.js';
import type { InboundEvent } from './channels/adapter.js';

function makeEvent(platformId: string, threadId: string | null, text: string): InboundEvent {
  return {
    channelType: 'ios-app-v2',
    platformId,
    threadId,
    message: {
      id: `m-${Math.random().toString(36).slice(2, 8)}`,
      kind: 'chat',
      content: JSON.stringify({ text }),
      timestamp: new Date().toISOString(),
    },
  };
}

describe('adapterRouteToAgent', () => {
  let tmp: string;
  beforeEach(() => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'adapter-route-'));
    process.env.DATA_DIR = tmp;
    const db = initTestDb();
    runMigrations(db);
    createAgentGroup({
      id: 'payne',
      name: 'Payne',
      folder: 'payne',
      agent_provider: null,
      created_at: new Date().toISOString(),
    });
    createMessagingGroup({
      id: 'mg-test',
      channel_type: 'ios-app-v2',
      platform_id: 'ios:test',
      name: 'iOS test',
      is_group: 0,
      unknown_sender_policy: 'strict',
      created_at: new Date().toISOString(),
      denied_at: null,
    });
  });
  afterEach(() => closeDb());

  it('creates a session for the addressed agent and writes the message into its inbound.db', async () => {
    const event = makeEvent('ios:test', null, 'hello payne');
    const res = await adapterRouteToAgent(event, 'payne', { wake: false });
    expect(res.delivered).toBe(true);
    const sess = findSessionForAgent('payne', 'mg-test', null);
    expect(sess).toBeDefined();
  });

  it('returns delivered=false with reason=unknown_agent when the agent group does not exist', async () => {
    const event = makeEvent('ios:test', null, 'hi ghost');
    const res = await adapterRouteToAgent(event, 'ghost', { wake: false });
    expect(res).toEqual({ delivered: false, reason: 'unknown_agent' });
  });

  it('returns delivered=false with reason=no_messaging_group when the platform id is unknown', async () => {
    const event = makeEvent('ios:nobody', null, 'hi');
    const res = await adapterRouteToAgent(event, 'payne', { wake: false });
    expect(res).toEqual({ delivered: false, reason: 'no_messaging_group' });
  });

  it('handles /new by resetting the existing session in place (same session, wiped continuation) without forwarding to the container', async () => {
    // Seed an existing session by sending a normal message first.
    await adapterRouteToAgent(makeEvent('ios:test', null, 'hello'), 'payne', { wake: false });
    const before = findSessionForAgent('payne', 'mg-test', null);
    expect(before).toBeDefined();

    const res = await adapterRouteToAgent(makeEvent('ios:test', null, '/new'), 'payne', { wake: false });
    expect(res.delivered).toBe(true);
    // Reset-in-place: the SAME session is returned (not a new dir/id). Its SDK
    // continuation is cleared so the next wake starts fresh; the session row
    // stays active and the reset notice lands on its outbound.
    expect(res.sessionId).toBe(before!.id);
    const after = findSessionForAgent('payne', 'mg-test', null);
    expect(after?.id).toBe(before?.id);
    expect(after?.status).toBe('active');
  });

  it('resolves the agent group by folder when id lookup misses', async () => {
    // Re-create with UUID-style id but folder='legacy'
    createAgentGroup({
      id: 'ag-uuid-style',
      name: 'Legacy Jarvis',
      folder: 'legacy',
      agent_provider: null,
      created_at: new Date().toISOString(),
    });
    const event = makeEvent('ios:test', null, 'hello legacy');
    const res = await adapterRouteToAgent(event, 'legacy', { wake: false });
    expect(res.delivered).toBe(true);
    const sess = findSessionForAgent('ag-uuid-style', 'mg-test', null);
    expect(sess).toBeDefined();
  });
});
