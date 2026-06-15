import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import path from 'path';
import os from 'os';
import fs from 'fs';

import { initTestDb, closeDb, createAgentGroup, createMessagingGroup } from './db/index.js';
import { createMessagingGroupAgent } from './db/messaging-groups.js';
import { runMigrations } from './db/migrations/index.js';
import { findSessionForAgent, getSession } from './db/sessions.js';
import { adapterRouteToAgent } from './adapter-route.js';
import type { InboundEvent } from './channels/adapter.js';
// Importing the permissions module installs the real sender resolver + access
// gate (module-level singletons on router.ts). vitest isolates test files, so
// this does not leak to other files — but within THIS file every test now runs
// with the real gate. The shared mg below is therefore `public` (gate
// short-circuits to allowed); the owner_key test uses a `strict` mg + addMember
// to exercise the membership path the iOS owner-stamping relies on.
import './modules/permissions/index.js';
import { upsertUser } from './modules/permissions/db/users.js';
import { addMember } from './modules/permissions/db/agent-group-members.js';

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
      // public so the now-installed access gate allows the gate-agnostic tests
      // below (which send no senderId → null userId).
      unknown_sender_policy: 'public',
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

  it('adapterRouteToAgent stamps session.owner_key from the sender person_key', async () => {
    // Person p2's device: a users row keyed by the platform_id carries
    // person_key='p2' (what validateToken's upsert guarantees at runtime).
    upsertUser({
      id: 'ios-app-v2:p2',
      kind: 'ios-app-v2',
      display_name: null,
      person_key: 'p2',
      created_at: new Date().toISOString(),
    });
    createAgentGroup({
      id: 'ag-jarvis',
      name: 'Jarvis',
      folder: 'jarvis',
      agent_provider: null,
      created_at: new Date().toISOString(),
    });
    createMessagingGroup({
      id: 'mg-p2',
      channel_type: 'ios-app-v2',
      platform_id: 'ios-app-v2:p2',
      name: 'p2 device',
      is_group: 0,
      // strict → the real access gate requires membership; addMember below
      // makes p2 a known member so the gate allows the message through.
      unknown_sender_policy: 'strict',
      created_at: new Date().toISOString(),
      denied_at: null,
    });
    createMessagingGroupAgent({
      id: 'mga-p2',
      messaging_group_id: 'mg-p2',
      agent_group_id: 'ag-jarvis',
      engage_mode: 'pattern',
      engage_pattern: '.',
      sender_scope: 'all',
      ignored_message_policy: 'drop',
      session_mode: 'shared',
      priority: 0,
      created_at: new Date().toISOString(),
    });
    addMember({
      user_id: 'ios-app-v2:p2',
      agent_group_id: 'ag-jarvis',
      added_by: null,
      added_at: new Date().toISOString(),
    });

    const res = await adapterRouteToAgent(
      {
        channelType: 'ios-app-v2',
        platformId: 'ios-app-v2:p2',
        threadId: null,
        message: {
          id: 'm1',
          kind: 'chat',
          content: JSON.stringify({ text: 'hi', senderId: 'ios-app-v2:p2' }),
          timestamp: new Date().toISOString(),
        },
      },
      'ag-jarvis',
      { wake: false },
    );

    expect(res.delivered).toBe(true);
    expect(getSession(res.sessionId!)?.owner_key).toBe('p2');
  });
});
