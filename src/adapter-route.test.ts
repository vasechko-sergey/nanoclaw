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
    createAgentGroup({ id: 'payne', name: 'Payne', folder: 'payne', agent_provider: null, created_at: new Date().toISOString() });
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
});
