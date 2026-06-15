import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import path from 'path';
import os from 'os';
import fs from 'fs';

import { initTestDb, closeDb, createMessagingGroup, getAllAgentGroups, getAgentGroupByFolder } from './db/index.js';
import { getMessagingGroupAgents } from './db/messaging-groups.js';
import { findSessionForAgent } from './db/sessions.js';
import { runMigrations } from './db/migrations/index.js';
import { getDestinationByTarget } from './modules/agent-to-agent/db/agent-destinations.js';

// Mock the session-manager so bootstrapTrio's writeSessionMessage /
// initSessionFolder calls (used for the bootstrap inbound) don't touch
// the real data/v2-sessions/ tree. DATA_DIR is a const captured at config
// import time, so we cannot redirect it via process.env in-test.
const writeCalls: Array<{ agentGroupId: string; sessionId: string; messageId: string; trigger: number }> = [];
vi.mock('./session-manager.js', async () => {
  const actual = await vi.importActual<typeof import('./session-manager.js')>('./session-manager.js');
  return {
    ...actual,
    initSessionFolder: vi.fn(),
    writeSessionMessage: vi.fn((agentGroupId: string, sessionId: string, msg: { id: string; trigger: number }) => {
      writeCalls.push({ agentGroupId, sessionId, messageId: msg.id, trigger: msg.trigger });
    }),
  };
});

import { bootstrapTrio } from './bootstrap-trio.js';

describe('bootstrapTrio', () => {
  beforeEach(() => {
    writeCalls.length = 0;
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'btrio-'));
    process.env.DATA_DIR = tmp;
    const db = initTestDb();
    runMigrations(db);
  });
  afterEach(() => closeDb());

  it('creates all five agent groups on first run', () => {
    bootstrapTrio();
    expect(getAgentGroupByFolder('jarvis')).toBeDefined();
    expect(getAgentGroupByFolder('payne')).toBeDefined();
    expect(getAgentGroupByFolder('greg')).toBeDefined();
    expect(getAgentGroupByFolder('gordon')).toBeDefined();
    expect(getAgentGroupByFolder('scrooge')).toBeDefined();
  });

  it('is idempotent on repeated runs', () => {
    bootstrapTrio();
    const firstCount = getAllAgentGroups().length;
    bootstrapTrio();
    expect(getAllAgentGroups().length).toBe(firstCount);
  });

  it('wires every team agent to any ios-app-v2 messaging group and eager-creates one session per agent', () => {
    createMessagingGroup({
      id: 'mg-ios',
      channel_type: 'ios-app-v2',
      platform_id: 'ios:abc',
      name: 'iPhone',
      is_group: 0,
      unknown_sender_policy: 'strict',
      created_at: new Date().toISOString(),
      denied_at: null,
    });
    bootstrapTrio();
    const wired = getMessagingGroupAgents('mg-ios')
      .map((r) => r.agent_group_id)
      .sort();
    expect(wired).toEqual(['gordon', 'greg', 'jarvis', 'payne', 'scrooge']);
    for (const slug of ['jarvis', 'payne', 'greg', 'gordon', 'scrooge']) {
      expect(findSessionForAgent(slug, 'mg-ios', null)).toBeDefined();
    }
  });

  it('writes a trigger=0 bootstrap inbound for payne, greg, gordon, and scrooge but not jarvis', () => {
    createMessagingGroup({
      id: 'mg-ios2',
      channel_type: 'ios-app-v2',
      platform_id: 'ios:def',
      name: 'iPhone2',
      is_group: 0,
      unknown_sender_policy: 'strict',
      created_at: new Date().toISOString(),
      denied_at: null,
    });
    bootstrapTrio();
    const agents = writeCalls.map((c) => c.agentGroupId).sort();
    expect(agents).toEqual(['gordon', 'greg', 'payne', 'scrooge']);
    for (const c of writeCalls) {
      expect(c.trigger).toBe(0);
    }
  });

  it('does not re-write the bootstrap message on a second bootstrap run', () => {
    createMessagingGroup({
      id: 'mg-ios3',
      channel_type: 'ios-app-v2',
      platform_id: 'ios:ghi',
      name: 'iPhone3',
      is_group: 0,
      unknown_sender_policy: 'strict',
      created_at: new Date().toISOString(),
      denied_at: null,
    });
    bootstrapTrio();
    const firstCount = writeCalls.length;
    bootstrapTrio();
    expect(writeCalls.length).toBe(firstCount);
  });

  it('wires every agent with a channel destination so replies resolve', () => {
    // bootstrap wires each agent via createMessagingGroupAgent, which
    // auto-creates the channel agent_destinations row. Without that row an
    // agent's <message> reply resolves to "Unknown" and the runner drops it,
    // so this guards that a freshly bootstrapped agent (e.g. gordon) can reply.
    createMessagingGroup({
      id: 'mg-ios4',
      channel_type: 'ios-app-v2',
      platform_id: 'ios:jkl',
      name: 'iPhone',
      is_group: 0,
      unknown_sender_policy: 'strict',
      created_at: new Date().toISOString(),
      denied_at: null,
    });
    bootstrapTrio();
    for (const slug of ['jarvis', 'payne', 'greg', 'gordon', 'scrooge']) {
      expect(getDestinationByTarget(slug, 'channel', 'mg-ios4')).toBeDefined();
    }
    // Idempotent: a second bootstrap must not throw on the PK or duplicate.
    bootstrapTrio();
    for (const slug of ['jarvis', 'payne', 'greg', 'gordon', 'scrooge']) {
      expect(getDestinationByTarget(slug, 'channel', 'mg-ios4')).toBeDefined();
    }
  });
});
