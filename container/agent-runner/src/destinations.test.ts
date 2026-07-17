import { afterEach, beforeEach, describe, expect, it } from 'bun:test';

import { closeSessionDb, getInboundDb, initTestSessionDb } from './db/connection.js';
import { buildSystemPromptAddendum, findByName, resolveDefaultRouting } from './destinations.js';

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
function seedAgentDestination(
  name: string,
  agentGroupId: string,
  a2aKinds: string | null,
  displayName: string = name,
): void {
  getInboundDb()
    .prepare(
      `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id, a2a_kinds)
       VALUES (?, ?, 'agent', NULL, NULL, ?, ?)`,
    )
    .run(name, displayName, agentGroupId, a2aKinds);
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

/**
 * The point of the whole normalization: what the agent is TOLD about a2a is
 * generated from `a2a_kinds` — the same descriptor projection the gate enforces
 * — instead of hand-copied into CLAUDE.md prose. Prose is what drifted.
 *
 * `buildSystemPromptAddendum()` with no assistant name returns exactly the
 * destinations section (the identity section is skipped), so these assert on
 * the section verbatim while still going through the real public entry point.
 */
describe('buildSystemPromptAddendum — legal kinds, generated from the descriptor', () => {
  it('lists legal kinds for an agent destination that has a descriptor', () => {
    seedAgentDestination('payne', 'ag-1', '["set_log","ack"]');
    seedDestination('casa', 'Casa', 'whatsapp', 'group-1@g.us');

    const prompt = buildSystemPromptAddendum();

    expect(prompt).toContain('`payne` — kind: set_log, ack');
  });

  it('puts the kind list after the display-name label', () => {
    seedAgentDestination('payne', 'ag-1', '["set_log"]', 'Майор Пейн');
    seedDestination('casa', 'Casa', 'whatsapp', 'group-1@g.us');

    const prompt = buildSystemPromptAddendum();

    expect(prompt).toContain('`payne` (Майор Пейн) — kind: set_log');
  });

  it('says nothing about kinds for an agent destination with no descriptor', () => {
    // `undescribed` has no agent.json → gate disarmed → nothing enforced, so
    // nothing to teach. Co-seeded with a DESCRIBED agent on purpose: that makes
    // the kind machinery active for this prompt, so the silence here can only
    // come from the null check in kindSuffix and not from the global guard.
    seedAgentDestination('described', 'ag-1', '["set_log"]');
    seedAgentDestination('undescribed', 'ag-2', null);

    const prompt = buildSystemPromptAddendum();

    expect(prompt).toContain('`described` — kind: set_log');
    expect(prompt).not.toContain('`undescribed` — kind:');
    expect(prompt).toMatch(/^- `undescribed`$/m);
  });

  it('says nothing about kinds for an agent destination that declares none', () => {
    // [] = has a descriptor, declares no kinds = gate ARMED text-only. There is
    // no list to print; an empty ` — kind: ` would be worse than silence.
    seedAgentDestination('described', 'ag-1', '["set_log"]');
    seedAgentDestination('textonly', 'ag-2', '[]');

    const prompt = buildSystemPromptAddendum();

    expect(prompt).not.toContain('`textonly` — kind:');
    expect(prompt).toMatch(/^- `textonly`$/m);
  });

  it('says nothing about kinds for channel destinations', () => {
    // The channel row carries a non-null a2a_kinds the host would never write.
    // A realistic (null) channel row cannot distinguish the type check from the
    // null check — both return ''. This one can: it fails if kindSuffix stops
    // checking `type`, which is what keeps a future projection change from
    // teaching kinds to a human-facing channel.
    seedAgentDestination('described', 'ag-1', '["set_log"]');
    getInboundDb()
      .prepare(
        `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id, a2a_kinds)
         VALUES ('family', 'Family', 'channel', 'whatsapp', 'group-1@g.us', NULL, '["set_log"]')`,
      )
      .run();

    const prompt = buildSystemPromptAddendum();

    expect(prompt).not.toMatch(/`family`[^\n]*kind:/);
    expect(prompt).toMatch(/^- `family` \(Family\)$/m);
  });

  it('documents the kind= attribute when any destination declares kinds', () => {
    seedAgentDestination('payne', 'ag-1', '["set_log","ack"]');
    seedDestination('casa', 'Casa', 'whatsapp', 'group-1@g.us');

    const prompt = buildSystemPromptAddendum();

    expect(prompt).toContain('kind=');
    expect(prompt).toContain('<message to="имя" kind="вид">');
  });

  it('lists kinds and documents kind= for a single agent destination', () => {
    // The single-destination branch is a separate code path from the bullet
    // list and drifts on its own if only the multi branch is covered.
    seedAgentDestination('payne', 'ag-1', '["set_log","ack"]');

    const prompt = buildSystemPromptAddendum();

    expect(prompt).toContain('Your destination is `payne` — kind: set_log, ack.');
    expect(prompt).toContain('kind=');
  });

  it('does not mention kind at all when no destination declares kinds', () => {
    // The pre-rollout state: zero agent.json exist, so every a2a_kinds is null
    // and every gate is disarmed. The addendum must then read exactly as it did
    // before this feature — the ship-inert property, made visible in the prompt.
    seedAgentDestination('undescribed', 'ag-1', null);
    seedDestination('casa', 'Casa', 'whatsapp', 'group-1@g.us');

    const prompt = buildSystemPromptAddendum();

    expect(prompt).toContain('`undescribed`');
    expect(prompt).not.toMatch(/kind/i);
  });
});

/**
 * The default-routing chain behind `send_message` with no `to` — and behind
 * the poll-loop's harness-error notice, which has no agent to ask "to where?".
 * A cron/headless turn is exactly where the notice matters most and where the
 * inbound batch's own routing is emptiest.
 */
describe('resolveDefaultRouting', () => {
  function seedSessionRouting(channelType: string | null, platformId: string | null, threadId: string | null): void {
    getInboundDb()
      .prepare(
        `INSERT INTO session_routing (id, channel_type, platform_id, thread_id) VALUES (1, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET channel_type = excluded.channel_type,
           platform_id = excluded.platform_id, thread_id = excluded.thread_id`,
      )
      .run(channelType, platformId, threadId);
  }

  function seedAgentDest(name: string, agentGroupId: string): void {
    getInboundDb()
      .prepare(
        `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id)
         VALUES (?, ?, 'agent', NULL, NULL, ?)`,
      )
      .run(name, name, agentGroupId);
  }

  it('prefers session routing, thread included', () => {
    seedSessionRouting('telegram', 'chat-99', 'thread-7');
    seedDestination('casa', 'Casa', 'whatsapp', 'group-1@g.us');

    expect(resolveDefaultRouting()).toEqual({
      ok: true,
      via: 'session',
      name: '(current conversation)',
      channel_type: 'telegram',
      platform_id: 'chat-99',
      thread_id: 'thread-7',
    });
  });

  it('falls back to the sole destination when the session has no routing', () => {
    // The headless case: no messaging group, so the host wrote no routing.
    seedDestination('casa', 'Casa', 'whatsapp', 'group-1@g.us');

    expect(resolveDefaultRouting()).toEqual({
      ok: true,
      via: 'sole-destination',
      name: 'casa',
      channel_type: 'whatsapp',
      platform_id: 'group-1@g.us',
      thread_id: null,
    });
  });

  it('resolves a sole agent destination to the agent channel', () => {
    seedAgentDest('payne', 'ag-payne');

    expect(resolveDefaultRouting()).toEqual({
      ok: true,
      via: 'sole-destination',
      name: 'payne',
      channel_type: 'agent',
      platform_id: 'ag-payne',
      thread_id: null,
    });
  });

  it('reports none when there is nowhere to send', () => {
    expect(resolveDefaultRouting()).toEqual({ ok: false, reason: 'none', options: [] });
  });

  it('refuses to guess between several destinations', () => {
    seedDestination('casa', 'Casa', 'whatsapp', 'group-1@g.us');
    seedAgentDest('payne', 'ag-payne');

    expect(resolveDefaultRouting()).toEqual({ ok: false, reason: 'ambiguous', options: ['casa', 'payne'] });
  });

  it('treats half-written session routing as absent', () => {
    // channel_type without platform_id is unroutable — must not win over a
    // destination that actually resolves.
    seedSessionRouting('telegram', null, null);
    seedDestination('casa', 'Casa', 'whatsapp', 'group-1@g.us');

    expect(resolveDefaultRouting()).toMatchObject({ ok: true, via: 'sole-destination' });
  });
});
