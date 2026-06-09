import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import path from 'path';
import os from 'os';
import fs from 'fs';

import { initTestDb, closeDb, createMessagingGroup, getAllAgentGroups, getAgentGroupByFolder } from './db/index.js';
import { getMessagingGroupAgents } from './db/messaging-groups.js';
import { findSessionForAgent } from './db/sessions.js';
import { runMigrations } from './db/migrations/index.js';
import { bootstrapTrio } from './bootstrap-trio.js';

describe('bootstrapTrio', () => {
  let tmp: string;
  beforeEach(() => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'btrio-'));
    process.env.DATA_DIR = tmp;
    const db = initTestDb();
    runMigrations(db);
  });
  afterEach(() => closeDb());

  it('creates the three agent groups on first run', () => {
    bootstrapTrio();
    expect(getAgentGroupByFolder('jarvis')).toBeDefined();
    expect(getAgentGroupByFolder('payne')).toBeDefined();
    expect(getAgentGroupByFolder('health-analyzer')).toBeDefined();
  });

  it('is idempotent on repeated runs', () => {
    bootstrapTrio();
    const firstCount = getAllAgentGroups().length;
    bootstrapTrio();
    expect(getAllAgentGroups().length).toBe(firstCount);
  });

  it('wires all three to any ios-app-v2 messaging group and eager-creates one session per agent', () => {
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
    const wired = getMessagingGroupAgents('mg-ios').map((r) => r.agent_group_id).sort();
    expect(wired).toEqual(['greg', 'jarvis', 'payne']);
    for (const slug of ['jarvis', 'payne', 'greg']) {
      expect(findSessionForAgent(slug, 'mg-ios', null)).toBeDefined();
    }
  });
});
