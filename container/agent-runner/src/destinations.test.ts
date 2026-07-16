import { afterEach, beforeEach, describe, expect, it } from 'bun:test';

import { closeSessionDb, getInboundDb, initTestSessionDb } from './db/connection.js';
import { buildSystemPromptAddendum, findByName } from './destinations.js';

beforeEach(() => {
  initTestSessionDb();
});

afterEach(() => {
  closeSessionDb();
});

function seedDestination(name: string, displayName: string, channelType: string, platformId: string): void {
  getInboundDb()
    .prepare(
      `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id)
       VALUES (?, ?, 'channel', ?, ?, NULL)`,
    )
    .run(name, displayName, channelType, platformId);
}

describe('buildSystemPromptAddendum — multi-destination routing guidance', () => {
  it('includes default-routing nudge when there are >1 destinations', () => {
    seedDestination('casa', 'Casa', 'whatsapp', 'group-1@g.us');
    seedDestination('whatsapp-mg-17780', 'whatsapp-mg-17780', 'whatsapp', 'phone-2@s.whatsapp.net');

    const prompt = buildSystemPromptAddendum('Casa');

    expect(prompt).toContain('default to addressing the destination it came `from`');
    expect(prompt).toContain('from="name"');
    expect(prompt).toContain('`casa`');
    expect(prompt).toContain('`whatsapp-mg-17780`');
  });

  it('describes message wrapping for a single destination', () => {
    seedDestination('casa', 'Casa', 'whatsapp', 'group-1@g.us');

    const prompt = buildSystemPromptAddendum('Casa');

    expect(prompt).toContain('Wrap each delivered message');
    expect(prompt).toContain('<message to="name">');
    expect(prompt).toContain('`casa`');
  });

  it('handles the no-destination case without crashing', () => {
    const prompt = buildSystemPromptAddendum('Casa');

    expect(prompt).toContain('no configured destinations');
    expect(prompt).not.toContain('default to addressing');
  });

  it('includes default-routing and wrapping instructions for single destination', () => {
    seedDestination('casa', 'Casa', 'whatsapp', 'group-1@g.us');

    const prompt = buildSystemPromptAddendum('Casa');

    expect(prompt).toContain('Wrap each delivered message');
    expect(prompt).toContain('<message to="name">');
    expect(prompt).toContain('default to addressing the destination it came `from`');
    expect(prompt).toContain('`casa`');
  });
});

/** Seed an agent destination with a raw `a2a_kinds` column value, as the host writes it. */
function seedAgentDestination(name: string, agentGroupId: string, a2aKinds: string | null): void {
  getInboundDb()
    .prepare(
      `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id, a2a_kinds)
       VALUES (?, ?, 'agent', NULL, NULL, ?, ?)`,
    )
    .run(name, name, agentGroupId, a2aKinds);
}

describe('destinations — a2aKinds', () => {
  it('surfaces the kinds the host projected for an agent target', () => {
    seedAgentDestination('payne', 'ag-1', '["set_log","ack"]');

    expect(findByName('payne')?.a2aKinds).toEqual(['set_log', 'ack']);
  });

  it('distinguishes an empty declaration ([] = gate armed, text-only) from null', () => {
    seedAgentDestination('greg', 'ag-2', '[]');

    expect(findByName('greg')?.a2aKinds).toEqual([]);
  });

  it('reads a null column as null — no descriptor, gate disarmed', () => {
    seedAgentDestination('jarvis', 'ag-3', null);

    expect(findByName('jarvis')?.a2aKinds).toBeNull();
  });

  it('reads unparseable JSON as null — fail open, never bounce everything over a corrupt row', () => {
    seedAgentDestination('broken', 'ag-4', '{ not json');

    expect(findByName('broken')?.a2aKinds).toBeNull();
  });

  it('reads well-formed JSON that is not an array as null', () => {
    seedAgentDestination('objecty', 'ag-5', '{"set_log":"desc"}');

    expect(findByName('objecty')?.a2aKinds).toBeNull();
  });

  it('drops non-string members rather than admitting them as kinds', () => {
    seedAgentDestination('mixed', 'ag-6', '["set_log",42,null,"ack"]');

    expect(findByName('mixed')?.a2aKinds).toEqual(['set_log', 'ack']);
  });

  it('reads a channel destination as null (host never writes kinds there)', () => {
    seedDestination('casa', 'Casa', 'whatsapp', 'group-1@g.us');

    expect(findByName('casa')?.a2aKinds).toBeNull();
  });
});
