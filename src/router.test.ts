/**
 * Characterization tests for src/router.ts.
 *
 * These lock down the *current* observable behavior of `routeInbound` and its
 * private decision helpers (`evaluateEngage`, `deliverToAgent`,
 * `messageIdForAgent`) as a regression safety net. They intentionally assert
 * what the code does today — surprising behaviors are captured with a
 * `// characterization: current behavior` note rather than "fixed".
 *
 * No containers are spawned: `./container-runner.js` is mocked so
 * `wakeContainer` / `killContainer` are inert spies. The router's only other
 * side effects are DB writes (central + per-session sqlite) and channel-adapter
 * calls, all of which run against a temp dir + in-memory-ish sqlite seeded by
 * the shared host harness (mirrors host-core.test.ts / delivery.test.ts).
 *
 * What existing host-core.test.ts already covers (NOT re-tested here):
 *   - basic end-to-end route + wake
 *   - auto-create mg only on mention/DM
 *   - fan-out to two pattern='.' agents
 *   - accumulate vs drop on a non-engaging mention wiring
 *
 * This file deliberately targets the *untested* decision branches:
 *   - evaluateEngage: pattern regex match/non-match, bad-regex fail-open,
 *     mention mode, mention-sticky (mention / sticky-session / DM short-circuit)
 *   - adapter thread policy (strip threadId; force per-thread + subscribe)
 *   - command gate integration (/new reset, filter, deny, rewrite)
 *   - access-gate + sender-scope-gate refusal (incl. the security rule that a
 *     gate refusal must NOT fall through to accumulate)
 *   - channel-registration gate / denied channel / no-gate drop
 *   - messageIdForAgent namespacing + empty-id synthesis
 *   - replyTo delivery-address override
 *   - dropped_messages audit rows
 */
import Database from 'better-sqlite3';
import fs from 'fs';
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';

// Mock the container runner BEFORE importing anything that pulls it in
// (router.ts imports wakeContainer/killContainer at module load). Match the
// shape used by host-core.test.ts so the spies line up.
vi.mock('./container-runner.js', () => ({
  wakeContainer: vi.fn().mockResolvedValue(true),
  isContainerRunning: vi.fn().mockReturnValue(false),
  getActiveContainerCount: vi.fn().mockReturnValue(0),
  killContainer: vi.fn(),
}));

vi.mock('./config.js', async () => {
  const actual = await vi.importActual<typeof import('./config.js')>('./config.js');
  return { ...actual, DATA_DIR: '/tmp/nanoclaw-test-router' };
});

const TEST_DIR = '/tmp/nanoclaw-test-router';

import {
  initTestDb,
  closeDb,
  runMigrations,
  createAgentGroup,
  createMessagingGroup,
  createMessagingGroupAgent,
} from './db/index.js';
import { getUnregisteredSenders } from './db/dropped-messages.js';
import { findSessionForAgent, getSessionsByAgentGroup } from './db/sessions.js';
import { setMessagingGroupDeniedAt } from './db/messaging-groups.js';
import { resolveSession, inboundDbPath, outboundDbPath } from './session-manager.js';
import { registerChannelAdapter, initChannelAdapters, teardownChannelAdapters } from './channels/channel-registry.js';
import {
  routeInbound,
  setSenderResolver,
  setAccessGate,
  setSenderScopeGate,
  setMessageInterceptor,
  setChannelRequestGate,
} from './router.js';
import type { InboundEvent, ChannelAdapter } from './channels/adapter.js';
import type { MessagingGroupAgent } from './types.js';

function now(): string {
  return new Date().toISOString();
}

// Default wiring fields the router reads; tests override per-case.
function agentWiring(
  overrides: Partial<MessagingGroupAgent> & { id: string; agent_group_id: string },
): MessagingGroupAgent {
  return {
    messaging_group_id: 'mg-1',
    engage_mode: 'pattern',
    engage_pattern: '.',
    sender_scope: 'all',
    ignored_message_policy: 'drop',
    session_mode: 'shared',
    priority: 0,
    created_at: now(),
    ...overrides,
  };
}

function chatEvent(over: {
  channelType?: string;
  platformId?: string;
  threadId?: string | null;
  id?: string;
  text?: string;
  isMention?: boolean;
  isGroup?: boolean;
  replyTo?: InboundEvent['replyTo'];
}): InboundEvent {
  return {
    channelType: over.channelType ?? 'discord',
    platformId: over.platformId ?? 'chan-123',
    threadId: over.threadId ?? null,
    message: {
      id: over.id ?? `msg-${Math.random().toString(36).slice(2)}`,
      kind: 'chat',
      content: JSON.stringify({ sender: 'User', text: over.text ?? 'hi' }),
      timestamp: now(),
      ...(over.isMention !== undefined ? { isMention: over.isMention } : {}),
      ...(over.isGroup !== undefined ? { isGroup: over.isGroup } : {}),
    },
    ...(over.replyTo ? { replyTo: over.replyTo } : {}),
  };
}

/** Read all messages_in rows for an agent's (single) session. */
function readInbound(agentGroupId: string): Array<{
  id: string;
  trigger: number;
  content: string;
  platform_id: string | null;
  channel_type: string | null;
  thread_id: string | null;
}> {
  const sessions = getSessionsByAgentGroup(agentGroupId);
  if (sessions.length === 0) return [];
  const db = new Database(inboundDbPath(agentGroupId, sessions[0].id));
  const rows = db
    .prepare('SELECT id, trigger, content, platform_id, channel_type, thread_id FROM messages_in ORDER BY rowid')
    .all() as Array<{
    id: string;
    trigger: number;
    content: string;
    platform_id: string | null;
    channel_type: string | null;
    thread_id: string | null;
  }>;
  db.close();
  return rows;
}

function readOutbound(agentGroupId: string, sessionId: string): Array<{ id: string; content: string }> {
  const db = new Database(outboundDbPath(agentGroupId, sessionId));
  const rows = db.prepare('SELECT id, content FROM messages_out ORDER BY rowid').all() as Array<{
    id: string;
    content: string;
  }>;
  db.close();
  return rows;
}

async function getMockWake(): Promise<ReturnType<typeof vi.fn>> {
  const { wakeContainer } = await import('./container-runner.js');
  return wakeContainer as unknown as ReturnType<typeof vi.fn>;
}

async function getMockKill(): Promise<ReturnType<typeof vi.fn>> {
  const { killContainer } = await import('./container-runner.js');
  return killContainer as unknown as ReturnType<typeof vi.fn>;
}

beforeEach(() => {
  if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true });
  fs.mkdirSync(TEST_DIR, { recursive: true });
  const db = initTestDb();
  runMigrations(db);

  // Router holds module-level hook singletons that survive across tests (and
  // across the whole module-import graph). There is no clear()/reset() — the
  // setters only warn-and-overwrite — so each test re-installs explicit
  // baseline hooks: allow-all gates, a null-returning sender resolver
  // (mirrors "no permissions module installed"), and pass-through
  // interceptor / channel-request hooks. Individual tests override as needed.
  setSenderResolver(() => null);
  setAccessGate(() => ({ allowed: true }));
  setSenderScopeGate(() => ({ allowed: true }));
  setMessageInterceptor(async () => false);
  setChannelRequestGate(async () => {});
});

afterEach(async () => {
  await teardownChannelAdapters();
  closeDb();
  vi.clearAllMocks();
  if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true });
});

// ─────────────────────────────────────────────────────────────────────────
// evaluateEngage — pattern mode
// ─────────────────────────────────────────────────────────────────────────
describe('routeInbound: pattern engage mode', () => {
  beforeEach(() => {
    createAgentGroup({ id: 'ag-1', name: 'Agent', folder: 'agent', agent_provider: null, created_at: now() });
    createMessagingGroup({
      id: 'mg-1',
      channel_type: 'discord',
      platform_id: 'chan-123',
      name: 'General',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
  });

  it('engages and wakes when the regex matches the text', async () => {
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_pattern: 'deploy' }));
    const wake = await getMockWake();

    await routeInbound(chatEvent({ text: 'please deploy now' }));

    expect(wake).toHaveBeenCalledTimes(1);
    const rows = readInbound('ag-1');
    expect(rows).toHaveLength(1);
    expect(rows[0].trigger).toBe(1);
  });

  it('does NOT engage (drop policy) when the regex does not match', async () => {
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_pattern: 'deploy' }));
    const wake = await getMockWake();

    await routeInbound(chatEvent({ text: 'unrelated chatter' }));

    expect(wake).not.toHaveBeenCalled();
    // No session created at all for a pure drop.
    expect(getSessionsByAgentGroup('ag-1')).toHaveLength(0);
  });

  it("treats engage_pattern '.' as match-everything (the always flavor)", async () => {
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_pattern: '.' }));
    const wake = await getMockWake();

    await routeInbound(chatEvent({ text: '' })); // empty text still engages

    expect(wake).toHaveBeenCalledTimes(1);
  });

  it("treats null engage_pattern as '.' / always-engage", async () => {
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_pattern: null }));
    const wake = await getMockWake();

    await routeInbound(chatEvent({ text: 'whatever' }));

    expect(wake).toHaveBeenCalledTimes(1);
  });

  it('fails OPEN on an invalid regex (engages so an admin can see + fix)', async () => {
    // characterization: current behavior — a malformed pattern engages rather
    // than silently dropping, so the misconfig is visible.
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_pattern: '([unterminated' }));
    const wake = await getMockWake();

    await routeInbound(chatEvent({ text: 'anything' }));

    expect(wake).toHaveBeenCalledTimes(1);
  });

  it('regex is matched against parsed JSON .text, not the raw content blob', async () => {
    // The wire content is {"sender":"User","text":"..."}. A pattern that only
    // appears in the JSON envelope (e.g. "sender") must NOT match — proving the
    // router tests parsed.text, not the raw string.
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_pattern: 'sender' }));
    const wake = await getMockWake();

    await routeInbound(chatEvent({ text: 'no keyword here' }));

    expect(wake).not.toHaveBeenCalled();
  });

  it('non-JSON content is treated as raw text for pattern matching', async () => {
    // safeParseContent falls back to { text: raw } on parse failure.
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_pattern: 'hello' }));
    const wake = await getMockWake();

    await routeInbound({
      channelType: 'discord',
      platformId: 'chan-123',
      threadId: null,
      message: { id: 'm-raw', kind: 'chat', content: 'hello there (not json)', timestamp: now() },
    });

    expect(wake).toHaveBeenCalledTimes(1);
  });
});

// ─────────────────────────────────────────────────────────────────────────
// evaluateEngage — mention mode
// ─────────────────────────────────────────────────────────────────────────
describe('routeInbound: mention engage mode', () => {
  beforeEach(() => {
    createAgentGroup({ id: 'ag-1', name: 'Agent', folder: 'agent', agent_provider: null, created_at: now() });
    createMessagingGroup({
      id: 'mg-1',
      channel_type: 'discord',
      platform_id: 'chan-123',
      name: 'General',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_mode: 'mention' }));
  });

  it('engages only when isMention is true', async () => {
    const wake = await getMockWake();
    await routeInbound(chatEvent({ text: '@bot hi', isMention: true }));
    expect(wake).toHaveBeenCalledTimes(1);
  });

  it('does not engage when isMention is absent (drop)', async () => {
    const wake = await getMockWake();
    // No isMention field at all — but mg already exists with an agent wired,
    // so the no-mention top-level short-circuit does NOT apply; we reach the
    // fan-out loop and evaluate('mention') returns false → drop.
    await routeInbound(chatEvent({ text: 'just talking' }));
    expect(wake).not.toHaveBeenCalled();
    expect(getSessionsByAgentGroup('ag-1')).toHaveLength(0);
  });
});

// ─────────────────────────────────────────────────────────────────────────
// evaluateEngage — mention-sticky mode
// ─────────────────────────────────────────────────────────────────────────
describe('routeInbound: mention-sticky engage mode', () => {
  beforeEach(() => {
    createAgentGroup({ id: 'ag-1', name: 'Agent', folder: 'agent', agent_provider: null, created_at: now() });
  });

  it('a mention engages even with no prior session', async () => {
    createMessagingGroup({
      id: 'mg-1',
      channel_type: 'discord',
      platform_id: 'chan-123',
      name: 'General',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_mode: 'mention-sticky' }));
    const wake = await getMockWake();

    await routeInbound(chatEvent({ threadId: 'thr-1', text: '@bot start', isMention: true }));

    expect(wake).toHaveBeenCalledTimes(1);
  });

  it('a follow-up with NO mention still engages once a session exists for that (agent, mg, thread)', async () => {
    createMessagingGroup({
      id: 'mg-1',
      channel_type: 'discord',
      platform_id: 'chan-123',
      name: 'General',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_mode: 'mention-sticky' }));
    const wake = await getMockWake();

    // First message mentions → engages → creates the per-thread session
    // (no adapter registered, so threadId is preserved and sticky lookup uses
    // it; session_mode 'shared' means the lookup thread is null though — see
    // findExistingSession). To make the sticky lookup find a session keyed by
    // this thread, the session must be stored with thread_id = threadId. With
    // an unregistered adapter + shared mode, resolveSession stores thread null,
    // so the sticky lookup (which queries thread-specific) would miss.
    //
    // characterization: we therefore pre-create the matching per-thread session
    // directly so evaluateEngage's findSessionForAgent(agent, mg, thread) hits.
    resolveSession('ag-1', 'mg-1', 'thr-sticky', 'per-thread');
    expect(findSessionForAgent('ag-1', 'mg-1', 'thr-sticky')).toBeDefined();

    await routeInbound(chatEvent({ threadId: 'thr-sticky', text: 'follow-up, no mention' }));

    expect(wake).toHaveBeenCalledTimes(1);
  });

  it('a follow-up with NO mention and NO existing session is dropped', async () => {
    createMessagingGroup({
      id: 'mg-1',
      channel_type: 'discord',
      platform_id: 'chan-123',
      name: 'General',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_mode: 'mention-sticky' }));
    const wake = await getMockWake();

    await routeInbound(chatEvent({ threadId: 'thr-cold', text: 'no mention, cold thread' }));

    expect(wake).not.toHaveBeenCalled();
  });

  it('in a DM (is_group=0) a non-mention never sticks, even with an existing session', async () => {
    // characterization: mention-sticky short-circuits to false for DMs before
    // any session lookup (the comment calls DMs "never sensible" for sticky).
    createMessagingGroup({
      id: 'mg-dm',
      channel_type: 'discord',
      platform_id: 'dm-chan',
      name: 'DM',
      is_group: 0,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    createMessagingGroupAgent(
      agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', messaging_group_id: 'mg-dm', engage_mode: 'mention-sticky' }),
    );
    // Pre-existing session for this DM.
    resolveSession('ag-1', 'mg-dm', null, 'shared');
    const wake = await getMockWake();

    await routeInbound(chatEvent({ platformId: 'dm-chan', text: 'hello again' }));

    expect(wake).not.toHaveBeenCalled();
  });
});

// ─────────────────────────────────────────────────────────────────────────
// Adapter thread policy (supportsThreads)
// ─────────────────────────────────────────────────────────────────────────
describe('routeInbound: adapter thread policy', () => {
  beforeEach(() => {
    createAgentGroup({ id: 'ag-1', name: 'Agent', folder: 'agent', agent_provider: null, created_at: now() });
  });

  async function mountAdapter(channelType: string, supportsThreads: boolean, subscribe?: ChannelAdapter['subscribe']) {
    const subscribeCalls: Array<[string, string]> = [];
    const adapter: ChannelAdapter = {
      name: channelType,
      channelType,
      supportsThreads,
      async setup() {},
      async teardown() {},
      isConnected() {
        return true;
      },
      async deliver() {
        return undefined;
      },
      async setTyping() {},
    };
    if (subscribe || supportsThreads) {
      adapter.subscribe = async (platformId: string, threadId: string) => {
        subscribeCalls.push([platformId, threadId]);
        if (subscribe) await subscribe(platformId, threadId);
      };
    }
    registerChannelAdapter(channelType, { factory: () => adapter });
    await initChannelAdapters(() => ({
      conversations: [],
      onInbound: () => {},
      onInboundEvent: () => {},
      onMetadata: () => {},
      onAction: () => {},
    }));
    return { subscribeCalls };
  }

  it('non-threaded adapter strips threadId before routing (collapses thread to channel)', async () => {
    await mountAdapter('telegram', false);
    createMessagingGroup({
      id: 'mg-tg',
      channel_type: 'telegram',
      platform_id: 'tg:1',
      name: 'TG',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    createMessagingGroupAgent(
      agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', messaging_group_id: 'mg-tg', session_mode: 'per-thread' }),
    );

    await routeInbound(chatEvent({ channelType: 'telegram', platformId: 'tg:1', threadId: 'should-be-stripped' }));

    const rows = readInbound('ag-1');
    expect(rows).toHaveLength(1);
    // thread_id on the stored row reflects the stripped (null) thread.
    expect(rows[0].thread_id).toBeNull();
    // And the session itself has a null thread (per-thread collapsed to shared
    // because adapter is non-threaded).
    const sessions = getSessionsByAgentGroup('ag-1');
    expect(sessions[0].thread_id).toBeNull();
  });

  it('threaded adapter in a group chat forces a per-thread session even for a shared wiring', async () => {
    await mountAdapter('discord', true);
    createMessagingGroup({
      id: 'mg-1',
      channel_type: 'discord',
      platform_id: 'chan-123',
      name: 'General',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', session_mode: 'shared' }));

    await routeInbound(chatEvent({ threadId: 'thr-A' }));

    const sessions = getSessionsByAgentGroup('ag-1');
    expect(sessions).toHaveLength(1);
    // Forced per-thread → session keyed by the thread despite shared wiring.
    expect(sessions[0].thread_id).toBe('thr-A');
  });

  it('mention-sticky on a threaded group chat fires adapter.subscribe once', async () => {
    const { subscribeCalls } = await mountAdapter('discord', true);
    createMessagingGroup({
      id: 'mg-1',
      channel_type: 'discord',
      platform_id: 'chan-123',
      name: 'General',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_mode: 'mention-sticky' }));

    await routeInbound(chatEvent({ threadId: 'thr-sub', text: '@bot subscribe me', isMention: true }));

    // subscribe is fire-and-forget; allow the microtask queue to flush.
    await Promise.resolve();
    expect(subscribeCalls).toEqual([['chan-123', 'thr-sub']]);
  });

  it('does NOT subscribe when there is no thread id (group chat, threadId null)', async () => {
    const { subscribeCalls } = await mountAdapter('discord', true);
    createMessagingGroup({
      id: 'mg-1',
      channel_type: 'discord',
      platform_id: 'chan-123',
      name: 'General',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_mode: 'mention-sticky' }));

    await routeInbound(chatEvent({ threadId: null, text: '@bot hi', isMention: true }));
    await Promise.resolve();

    expect(subscribeCalls).toHaveLength(0);
  });
});

// ─────────────────────────────────────────────────────────────────────────
// Command gate integration (deliverToAgent)
// ─────────────────────────────────────────────────────────────────────────
describe('routeInbound: command gate', () => {
  beforeEach(() => {
    createAgentGroup({ id: 'ag-1', name: 'Agent', folder: 'agent', agent_provider: null, created_at: now() });
    createMessagingGroup({
      id: 'mg-1',
      channel_type: 'discord',
      platform_id: 'chan-123',
      name: 'General',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_pattern: '.' }));
  });

  it('filtered slash command (/help) is dropped silently — no session, no wake', async () => {
    const wake = await getMockWake();
    await routeInbound(chatEvent({ text: '/help' }));
    expect(wake).not.toHaveBeenCalled();
    // characterization: the gate's filter return happens AFTER engage but
    // BEFORE resolveSession, so no session row is created.
    expect(getSessionsByAgentGroup('ag-1')).toHaveLength(0);
  });

  it('/new resets the session: kills the old container, closes old session, writes a fresh-start outbound notice', async () => {
    const wake = await getMockWake();
    const kill = await getMockKill();

    // Seed an existing session so /new has something to close.
    const { session: old } = resolveSession('ag-1', 'mg-1', null, 'shared');

    await routeInbound(chatEvent({ text: '/new' }));

    expect(kill).toHaveBeenCalledWith(old.id, '/new command');
    // /new returns before the wake branch — no container wake.
    expect(wake).not.toHaveBeenCalled();

    // A brand-new session exists (old one closed) and carries the reset notice
    // on its OUTBOUND db (written directly, not through the agent).
    const sessions = getSessionsByAgentGroup('ag-1');
    const fresh = sessions.find((s) => s.status === 'active');
    expect(fresh).toBeDefined();
    expect(fresh!.id).not.toBe(old.id);
    const out = readOutbound('ag-1', fresh!.id);
    expect(out).toHaveLength(1);
    expect(JSON.parse(out[0].content).text).toContain('Контекст сброшен');
  });

  it('denied admin command (/clear by a non-admin) writes a permission-denied outbound, no wake', async () => {
    // With a non-null userId and the user_roles table present (migrations ran)
    // but no role rows, isAdmin() returns false → gate denies.
    setSenderResolver(() => 'discord:stranger');
    const wake = await getMockWake();

    await routeInbound(chatEvent({ text: '/clear' }));

    expect(wake).not.toHaveBeenCalled();
    const sessions = getSessionsByAgentGroup('ag-1');
    expect(sessions).toHaveLength(1);
    const out = readOutbound('ag-1', sessions[0].id);
    expect(out).toHaveLength(1);
    expect(JSON.parse(out[0].content).text).toContain('Permission denied');
  });

  it('rewrite command (/surf) is rewritten to plain text and routed normally', async () => {
    const wake = await getMockWake();
    await routeInbound(chatEvent({ text: '/surf' }));

    expect(wake).toHaveBeenCalledTimes(1);
    const rows = readInbound('ag-1');
    expect(rows).toHaveLength(1);
    // /surf → 'прогноз серфинга' (see command-gate REWRITE_COMMANDS)
    expect(JSON.parse(rows[0].content).text).toBe('прогноз серфинга');
  });

  it('an unknown slash command passes through unchanged to the container', async () => {
    const wake = await getMockWake();
    await routeInbound(chatEvent({ text: '/unknown-thing arg' }));

    expect(wake).toHaveBeenCalledTimes(1);
    const rows = readInbound('ag-1');
    expect(JSON.parse(rows[0].content).text).toBe('/unknown-thing arg');
  });
});

// ─────────────────────────────────────────────────────────────────────────
// Access gate + sender-scope gate
// ─────────────────────────────────────────────────────────────────────────
describe('routeInbound: access + sender-scope gates', () => {
  beforeEach(() => {
    createAgentGroup({ id: 'ag-1', name: 'Agent', folder: 'agent', agent_provider: null, created_at: now() });
    createMessagingGroup({
      id: 'mg-1',
      channel_type: 'discord',
      platform_id: 'chan-123',
      name: 'General',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
  });

  it('access-gate refusal drops the message even when engage would fire', async () => {
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_pattern: '.' }));
    setAccessGate(() => ({ allowed: false, reason: 'not_member' }));
    const wake = await getMockWake();

    await routeInbound(chatEvent({ text: 'let me in' }));

    expect(wake).not.toHaveBeenCalled();
    expect(getSessionsByAgentGroup('ag-1')).toHaveLength(0);
  });

  it('SECURITY: a gate refusal does NOT fall through to accumulate (untrusted sender context is not stored)', async () => {
    // This is the line 318 guard: engage fired + access refused must skip the
    // accumulate branch entirely, even with ignored_message_policy=accumulate.
    createMessagingGroupAgent(
      agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_pattern: '.', ignored_message_policy: 'accumulate' }),
    );
    setAccessGate(() => ({ allowed: false, reason: 'untrusted' }));
    const wake = await getMockWake();

    await routeInbound(chatEvent({ text: 'sneaky context' }));

    expect(wake).not.toHaveBeenCalled();
    // No session, no stored message — the refusal wins over accumulate.
    expect(getSessionsByAgentGroup('ag-1')).toHaveLength(0);
  });

  it('sender-scope-gate refusal also drops (per-wiring stricter than mg policy)', async () => {
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_pattern: '.' }));
    setSenderScopeGate(() => ({ allowed: false, reason: 'sender_scope_known' }));
    const wake = await getMockWake();

    await routeInbound(chatEvent({ text: 'hi' }));

    expect(wake).not.toHaveBeenCalled();
    expect(getSessionsByAgentGroup('ag-1')).toHaveLength(0);
  });

  it('userId from the sender resolver is threaded into the gate', async () => {
    let seenUserId: string | null | undefined;
    setSenderResolver(() => 'discord:alice');
    setAccessGate((_event, userId) => {
      seenUserId = userId;
      return { allowed: true };
    });
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_pattern: '.' }));

    await routeInbound(chatEvent({ text: 'hi' }));

    expect(seenUserId).toBe('discord:alice');
  });
});

// ─────────────────────────────────────────────────────────────────────────
// No-wiring branch: channel-registration gate / denied / no-gate drop
// ─────────────────────────────────────────────────────────────────────────
describe('routeInbound: unwired-channel handling', () => {
  it('mention on a wired-mg-but-zero-agents channel calls the channel-request gate and records a dropped message', async () => {
    // Pre-create the mg with NO agents, then mention it.
    createMessagingGroup({
      id: 'mg-empty',
      channel_type: 'discord',
      platform_id: 'chan-empty',
      name: 'Empty',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    const gateCalls: string[] = [];
    setChannelRequestGate(async (mg) => {
      gateCalls.push(mg.id);
    });

    await routeInbound(chatEvent({ platformId: 'chan-empty', text: '@bot please register', isMention: true }));

    expect(gateCalls).toEqual(['mg-empty']);
    const dropped = getUnregisteredSenders();
    expect(dropped.some((d) => d.reason === 'no_agent_wired' && d.platform_id === 'chan-empty')).toBe(true);
  });

  it('mention on a DENIED channel drops silently — no gate call, no dropped-message row', async () => {
    createMessagingGroup({
      id: 'mg-denied',
      channel_type: 'discord',
      platform_id: 'chan-denied',
      name: 'Denied',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    setMessagingGroupDeniedAt('mg-denied', now());
    const gateCalls: string[] = [];
    setChannelRequestGate(async (mg) => {
      gateCalls.push(mg.id);
    });

    await routeInbound(chatEvent({ platformId: 'chan-denied', text: '@bot hi', isMention: true }));

    // characterization: denied channels short-circuit BEFORE recording a drop
    // and before the gate — total silence.
    expect(gateCalls).toEqual([]);
    expect(getUnregisteredSenders().some((d) => d.platform_id === 'chan-denied')).toBe(false);
  });

  it('non-mention on an unwired-but-existing mg returns silently (no drop row, no gate)', async () => {
    createMessagingGroup({
      id: 'mg-empty',
      channel_type: 'discord',
      platform_id: 'chan-empty',
      name: 'Empty',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    const gateCalls: string[] = [];
    setChannelRequestGate(async (mg) => {
      gateCalls.push(mg.id);
    });

    await routeInbound(chatEvent({ platformId: 'chan-empty', text: 'idle chatter' }));

    expect(gateCalls).toEqual([]);
    expect(getUnregisteredSenders()).toHaveLength(0);
  });

  it('the message interceptor can consume a message before any routing', async () => {
    createMessagingGroup({
      id: 'mg-1',
      channel_type: 'discord',
      platform_id: 'chan-123',
      name: 'General',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    createAgentGroup({ id: 'ag-1', name: 'Agent', folder: 'agent', agent_provider: null, created_at: now() });
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_pattern: '.' }));

    setMessageInterceptor(async () => true); // consume everything
    const wake = await getMockWake();

    await routeInbound(chatEvent({ text: 'this never routes' }));

    expect(wake).not.toHaveBeenCalled();
    expect(getSessionsByAgentGroup('ag-1')).toHaveLength(0);
  });
});

// ─────────────────────────────────────────────────────────────────────────
// no_agent_engaged audit row
// ─────────────────────────────────────────────────────────────────────────
describe('routeInbound: no_agent_engaged audit', () => {
  it('records reason=no_agent_engaged when wired agents all decline (drop)', async () => {
    createAgentGroup({ id: 'ag-1', name: 'Agent', folder: 'agent', agent_provider: null, created_at: now() });
    createMessagingGroup({
      id: 'mg-1',
      channel_type: 'discord',
      platform_id: 'chan-123',
      name: 'General',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    // mention wiring, non-mention message → declines, drop policy.
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_mode: 'mention' }));

    await routeInbound(chatEvent({ text: 'no mention' }));

    const dropped = getUnregisteredSenders();
    expect(dropped.some((d) => d.reason === 'no_agent_engaged')).toBe(true);
  });

  it('does NOT record no_agent_engaged when at least one agent accumulates', async () => {
    createAgentGroup({ id: 'ag-1', name: 'Agent', folder: 'agent', agent_provider: null, created_at: now() });
    createMessagingGroup({
      id: 'mg-1',
      channel_type: 'discord',
      platform_id: 'chan-123',
      name: 'General',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    createMessagingGroupAgent(
      agentWiring({
        id: 'mga-1',
        agent_group_id: 'ag-1',
        engage_mode: 'mention',
        ignored_message_policy: 'accumulate',
      }),
    );

    await routeInbound(chatEvent({ text: 'no mention' }));

    // accumulatedCount > 0 → the no_agent_engaged drop row is NOT written.
    expect(getUnregisteredSenders().some((d) => d.reason === 'no_agent_engaged')).toBe(false);
    // And the message is stored as silent context (trigger=0).
    const rows = readInbound('ag-1');
    expect(rows).toHaveLength(1);
    expect(rows[0].trigger).toBe(0);
  });
});

// ─────────────────────────────────────────────────────────────────────────
// messageIdForAgent namespacing + fan-out id uniqueness
// ─────────────────────────────────────────────────────────────────────────
describe('routeInbound: per-agent message id namespacing', () => {
  it('stamps the stored row id as "<baseId>:<agentGroupId>"', async () => {
    createAgentGroup({ id: 'ag-1', name: 'Agent', folder: 'agent', agent_provider: null, created_at: now() });
    createMessagingGroup({
      id: 'mg-1',
      channel_type: 'discord',
      platform_id: 'chan-123',
      name: 'General',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_pattern: '.' }));

    await routeInbound(chatEvent({ id: 'base-42', text: 'hi' }));

    const rows = readInbound('ag-1');
    expect(rows).toHaveLength(1);
    expect(rows[0].id).toBe('base-42:ag-1');
  });

  it('fan-out: the same base id lands once per agent, namespaced so no PK collision occurs', async () => {
    createAgentGroup({ id: 'ag-1', name: 'A1', folder: 'a1', agent_provider: null, created_at: now() });
    createAgentGroup({ id: 'ag-2', name: 'A2', folder: 'a2', agent_provider: null, created_at: now() });
    createMessagingGroup({
      id: 'mg-1',
      channel_type: 'discord',
      platform_id: 'chan-123',
      name: 'General',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_pattern: '.' }));
    createMessagingGroupAgent(agentWiring({ id: 'mga-2', agent_group_id: 'ag-2', engage_pattern: '.' }));

    await routeInbound(chatEvent({ id: 'shared-base', text: 'broadcast' }));

    expect(readInbound('ag-1').map((r) => r.id)).toEqual(['shared-base:ag-1']);
    expect(readInbound('ag-2').map((r) => r.id)).toEqual(['shared-base:ag-2']);
  });

  it('synthesizes a base id when the inbound message id is empty', async () => {
    createAgentGroup({ id: 'ag-1', name: 'Agent', folder: 'agent', agent_provider: null, created_at: now() });
    createMessagingGroup({
      id: 'mg-1',
      channel_type: 'discord',
      platform_id: 'chan-123',
      name: 'General',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_pattern: '.' }));

    await routeInbound({
      channelType: 'discord',
      platformId: 'chan-123',
      threadId: null,
      message: { id: '', kind: 'chat', content: JSON.stringify({ text: 'noid' }), timestamp: now() },
    });

    const rows = readInbound('ag-1');
    expect(rows).toHaveLength(1);
    // characterization: empty id → synthesized "msg-<ts>-<rand>" base, then
    // ":<agentGroupId>" suffix.
    expect(rows[0].id).toMatch(/^msg-\d+-[a-z0-9]+:ag-1$/);
  });
});

// ─────────────────────────────────────────────────────────────────────────
// replyTo delivery-address override
// ─────────────────────────────────────────────────────────────────────────
describe('routeInbound: replyTo override (admin transport)', () => {
  it('stamps the stored row with the replyTo address, not the source address', async () => {
    createAgentGroup({ id: 'ag-1', name: 'Agent', folder: 'agent', agent_provider: null, created_at: now() });
    createMessagingGroup({
      id: 'mg-1',
      channel_type: 'discord',
      platform_id: 'chan-123',
      name: 'General',
      is_group: 1,
      unknown_sender_policy: 'public',
      created_at: now(),
    });
    createMessagingGroupAgent(agentWiring({ id: 'mga-1', agent_group_id: 'ag-1', engage_pattern: '.' }));

    await routeInbound(
      chatEvent({
        text: 'routed to discord, reply to cli',
        replyTo: { channelType: 'cli', platformId: 'operator-term', threadId: 'tty-7' },
      }),
    );

    const rows = readInbound('ag-1');
    expect(rows).toHaveLength(1);
    // The messages_in row carries the REPLY address (where the agent's answer
    // goes), overriding the discord source.
    expect(rows[0].channel_type).toBe('cli');
    expect(rows[0].platform_id).toBe('operator-term');
    expect(rows[0].thread_id).toBe('tty-7');
  });
});
