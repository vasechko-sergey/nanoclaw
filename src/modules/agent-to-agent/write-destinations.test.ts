/**
 * writeDestinations projects the central `agent_destinations` rows into a
 * session's inbound.db on every container wake.
 *
 * The load-bearing part here is `a2a_kinds`: for an agent target it records
 * what THAT TARGET accepts, read from the target's own agent.json — the same
 * file the registry publishes to peers. NULL means the target has no usable
 * descriptor, which disarms the gate downstream. No descriptors exist in the
 * wild yet, so today every row is NULL and the projection is inert.
 */
import Database from 'better-sqlite3';
import fs from 'fs';
import path from 'path';
import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest';

import { createDestination } from './db/agent-destinations.js';
import { writeDestinations } from './write-destinations.js';
import { initTestDb, closeDb, runMigrations, createAgentGroup } from '../../db/index.js';
import { createMessagingGroup } from '../../db/messaging-groups.js';
import { createSession } from '../../db/sessions.js';
import { initSessionFolder, inboundDbPath } from '../../session-manager.js';

const TEST_DIR = '/tmp/nanoclaw-test-a2a-write-dest';
const AGENTS_DIR = path.join(TEST_DIR, 'agents');

vi.mock('../../config.js', async () => {
  const actual = await vi.importActual('../../config.js');
  return {
    ...actual,
    DATA_DIR: '/tmp/nanoclaw-test-a2a-write-dest',
    AGENTS_DIR: '/tmp/nanoclaw-test-a2a-write-dest/agents',
  };
});

const SOURCE_AG = 'ag-source';
const SESSION_ID = 'sess-source';

function now(): string {
  return new Date().toISOString();
}

/** Author `<AGENTS_DIR>/<folder>/agent.json` — the target's own descriptor. */
function writeDescriptor(folder: string, descriptor: unknown): void {
  const dir = path.join(AGENTS_DIR, folder);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'agent.json'), JSON.stringify(descriptor));
}

function seedAgent(id: string, folder: string, name: string): void {
  createAgentGroup({ id, name, folder, agent_provider: null, created_at: now() });
}

/** Read the projected rows back out of the session's inbound.db. */
function readProjected(): Array<{ name: string; type: string; a2a_kinds: string | null }> {
  const db = new Database(inboundDbPath(SOURCE_AG, SESSION_ID), { readonly: true });
  const rows = db.prepare('SELECT name, type, a2a_kinds FROM destinations ORDER BY name').all() as Array<{
    name: string;
    type: string;
    a2a_kinds: string | null;
  }>;
  db.close();
  return rows;
}

beforeEach(() => {
  if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true, force: true });
  fs.mkdirSync(AGENTS_DIR, { recursive: true });
  const db = initTestDb();
  runMigrations(db);

  seedAgent(SOURCE_AG, 'source', 'Source');
  createSession({
    id: SESSION_ID,
    agent_group_id: SOURCE_AG,
    messaging_group_id: null,
    thread_id: null,
    owner_key: null,
    agent_provider: null,
    status: 'active',
    container_status: 'stopped',
    last_active: null,
    created_at: now(),
  });
  initSessionFolder(SOURCE_AG, SESSION_ID);
});

afterEach(() => {
  closeDb();
  if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true, force: true });
});

describe('writeDestinations — a2a_kinds projection', () => {
  it('records the kinds an agent target declares in its own descriptor', () => {
    seedAgent('ag-payne', 'payne', 'Майор Пейн');
    writeDescriptor('payne', {
      role: 'Тренер',
      a2a_in: { set_log: 'записать подход', workout_done: 'закрыть тренировку' },
    });
    createDestination({
      agent_group_id: SOURCE_AG,
      local_name: 'payne',
      target_type: 'agent',
      target_id: 'ag-payne',
      created_at: now(),
    });

    writeDestinations(SOURCE_AG, SESSION_ID);

    expect(readProjected()).toEqual([{ name: 'payne', type: 'agent', a2a_kinds: '["set_log","workout_done"]' }]);
  });

  it('projects [] — not null — for a target whose descriptor declares no kinds', () => {
    // Text-only agent: HAS a descriptor, accepts no structured kinds. The gate
    // must stay ARMED for it, so this may never collapse to null.
    seedAgent('ag-greg', 'greg', 'Greg');
    writeDescriptor('greg', { role: 'Аналитик' });
    createDestination({
      agent_group_id: SOURCE_AG,
      local_name: 'greg',
      target_type: 'agent',
      target_id: 'ag-greg',
      created_at: now(),
    });

    writeDestinations(SOURCE_AG, SESSION_ID);

    expect(readProjected()).toEqual([{ name: 'greg', type: 'agent', a2a_kinds: '[]' }]);
  });

  it('projects null for an agent target with no descriptor (gate disarmed)', () => {
    // The ship-inert case: zero descriptors exist today, so this is what every
    // real row looks like right now.
    seedAgent('ag-jarvis', 'jarvis', 'Jarvis');
    createDestination({
      agent_group_id: SOURCE_AG,
      local_name: 'jarvis',
      target_type: 'agent',
      target_id: 'ag-jarvis',
      created_at: now(),
    });

    writeDestinations(SOURCE_AG, SESSION_ID);

    expect(readProjected()).toEqual([{ name: 'jarvis', type: 'agent', a2a_kinds: null }]);
  });

  it('projects null for an agent target whose descriptor is malformed (fails open)', () => {
    seedAgent('ag-broken', 'broken', 'Broken');
    fs.mkdirSync(path.join(AGENTS_DIR, 'broken'), { recursive: true });
    fs.writeFileSync(path.join(AGENTS_DIR, 'broken', 'agent.json'), '{ not json');
    createDestination({
      agent_group_id: SOURCE_AG,
      local_name: 'broken',
      target_type: 'agent',
      target_id: 'ag-broken',
      created_at: now(),
    });

    writeDestinations(SOURCE_AG, SESSION_ID);

    expect(readProjected()).toEqual([{ name: 'broken', type: 'agent', a2a_kinds: null }]);
  });

  it('projects null for a channel target — a2a kinds are meaningless there', () => {
    // Even when a same-named agents/<folder>/agent.json exists, a channel row
    // must never pick kinds up: `family` is a Telegram chat, not an agent.
    writeDescriptor('family', { a2a_in: { set_log: 'nope' } });
    createMessagingGroup({
      id: 'mg-family',
      channel_type: 'telegram',
      platform_id: '-100',
      name: 'Семья',
      is_group: 1,
      unknown_sender_policy: 'strict',
      created_at: now(),
    });
    createDestination({
      agent_group_id: SOURCE_AG,
      local_name: 'family',
      target_type: 'channel',
      target_id: 'mg-family',
      created_at: now(),
    });

    writeDestinations(SOURCE_AG, SESSION_ID);

    expect(readProjected()).toEqual([{ name: 'family', type: 'channel', a2a_kinds: null }]);
  });

  it('resolves each target against its OWN descriptor, not the first one found', () => {
    seedAgent('ag-payne', 'payne', 'Майор Пейн');
    seedAgent('ag-greg', 'greg', 'Greg');
    writeDescriptor('payne', { a2a_in: { set_log: 'записать подход' } });
    writeDescriptor('greg', { a2a_in: { health_query: 'спросить про здоровье' } });
    for (const [localName, targetId] of [
      ['payne', 'ag-payne'],
      ['greg', 'ag-greg'],
    ]) {
      createDestination({
        agent_group_id: SOURCE_AG,
        local_name: localName,
        target_type: 'agent',
        target_id: targetId,
        created_at: now(),
      });
    }

    writeDestinations(SOURCE_AG, SESSION_ID);

    expect(readProjected()).toEqual([
      { name: 'greg', type: 'agent', a2a_kinds: '["health_query"]' },
      { name: 'payne', type: 'agent', a2a_kinds: '["set_log"]' },
    ]);
  });
});
