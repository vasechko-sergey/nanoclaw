import Database from 'better-sqlite3';
import fs from 'fs';
import path from 'path';
import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest';

import { isSafeAttachmentName, resolveTargetSession, routeAgentMessage, stampSenderIdentity } from './agent-route.js';
import { createDestination } from './db/agent-destinations.js';
import { initTestDb, closeDb, runMigrations, createAgentGroup } from '../../db/index.js';
import { createSession, updateSession } from '../../db/sessions.js';
import { initSessionFolder, inboundDbPath, sessionDir, writeSessionMessage } from '../../session-manager.js';
import type { Session } from '../../types.js';

vi.mock('../../container-runner.js', () => ({
  wakeContainer: vi.fn().mockResolvedValue(undefined),
  isContainerRunning: vi.fn().mockReturnValue(false),
  getActiveContainerCount: vi.fn().mockReturnValue(0),
  killContainer: vi.fn(),
}));

vi.mock('../../config.js', async () => {
  const actual = await vi.importActual('../../config.js');
  return {
    ...actual,
    DATA_DIR: '/tmp/nanoclaw-test-a2a-route',
    // The gate reads the TARGET's agent.json from here. Pointed at the temp
    // tree so a test can author one; with none authored it resolves to null
    // (gate disarmed), which is the state of every agent in the wild today.
    AGENTS_DIR: '/tmp/nanoclaw-test-a2a-route/agents',
  };
});

const TEST_DIR = '/tmp/nanoclaw-test-a2a-route';
const TEST_AGENTS_DIR = '/tmp/nanoclaw-test-a2a-route/agents';

function now(): string {
  return new Date().toISOString();
}

function readInbound(agentGroupId: string, sessionId: string) {
  const db = new Database(inboundDbPath(agentGroupId, sessionId), { readonly: true });
  const rows = db
    .prepare('SELECT id, platform_id, channel_type, content, source_session_id FROM messages_in ORDER BY seq')
    .all() as Array<{
    id: string;
    platform_id: string | null;
    channel_type: string | null;
    content: string;
    source_session_id: string | null;
  }>;
  db.close();
  return rows;
}

describe('isSafeAttachmentName', () => {
  it('accepts plain filenames', () => {
    expect(isSafeAttachmentName('baby-duck.png')).toBe(true);
    expect(isSafeAttachmentName('file with spaces.pdf')).toBe(true);
    expect(isSafeAttachmentName('report.v2.docx')).toBe(true);
    expect(isSafeAttachmentName('.hidden')).toBe(true);
  });

  it('rejects empty / sentinel values', () => {
    expect(isSafeAttachmentName('')).toBe(false);
    expect(isSafeAttachmentName('.')).toBe(false);
    expect(isSafeAttachmentName('..')).toBe(false);
  });

  it('rejects path separators', () => {
    expect(isSafeAttachmentName('../evil.png')).toBe(false);
    expect(isSafeAttachmentName('/etc/passwd')).toBe(false);
    expect(isSafeAttachmentName('nested/file.txt')).toBe(false);
    expect(isSafeAttachmentName('windows\\path.exe')).toBe(false);
  });

  it('rejects NUL bytes', () => {
    expect(isSafeAttachmentName('clean\0.png')).toBe(false);
  });

  it('rejects anything path.basename would strip', () => {
    expect(isSafeAttachmentName('a/b')).toBe(false);
    expect(isSafeAttachmentName('./thing')).toBe(false);
  });

  it('rejects non-string input', () => {
    expect(isSafeAttachmentName(null as unknown as string)).toBe(false);
    expect(isSafeAttachmentName(undefined as unknown as string)).toBe(false);
  });
});

/**
 * Return-path routing: when an a2a reply targets an agent group with multiple
 * sessions, it must land in the *originating* session — not the newest one.
 *
 * Setup: agent A has two active sessions S1 (older) + S2 (newer).
 * Agent B is the peer A talks to. Bidirectional destinations wired.
 */
describe('routeAgentMessage return-path', () => {
  const A = 'ag-A';
  const B = 'ag-B';
  let S1: Session;
  let S2: Session;
  let SB: Session;

  beforeEach(() => {
    if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true });
    fs.mkdirSync(TEST_DIR, { recursive: true });

    const db = initTestDb();
    runMigrations(db);

    createAgentGroup({ id: A, name: 'A', folder: 'a', agent_provider: null, created_at: now() });
    createAgentGroup({ id: B, name: 'B', folder: 'b', agent_provider: null, created_at: now() });

    // S1 (older), S2 (newer) — both active sessions on A.
    S1 = {
      id: 'sess-A-old',
      agent_group_id: A,
      messaging_group_id: null,
      thread_id: null,
      owner_key: null,
      agent_provider: null,
      status: 'active',
      container_status: 'stopped',
      last_active: null,
      created_at: '2026-01-01T00:00:00.000Z',
    };
    S2 = {
      id: 'sess-A-new',
      agent_group_id: A,
      messaging_group_id: null,
      thread_id: null,
      owner_key: null,
      agent_provider: null,
      status: 'active',
      container_status: 'stopped',
      last_active: null,
      created_at: '2026-02-01T00:00:00.000Z',
    };
    SB = {
      id: 'sess-B',
      agent_group_id: B,
      messaging_group_id: null,
      thread_id: null,
      owner_key: null,
      agent_provider: null,
      status: 'active',
      container_status: 'stopped',
      last_active: null,
      created_at: '2026-01-15T00:00:00.000Z',
    };
    createSession(S1);
    createSession(S2);
    createSession(SB);
    initSessionFolder(A, S1.id);
    initSessionFolder(A, S2.id);
    initSessionFolder(B, SB.id);

    createDestination({
      agent_group_id: A,
      local_name: 'b',
      target_type: 'agent',
      target_id: B,
      created_at: now(),
    });
    createDestination({
      agent_group_id: B,
      local_name: 'a',
      target_type: 'agent',
      target_id: A,
      created_at: now(),
    });
  });

  afterEach(() => {
    closeDb();
    if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true });
  });

  it('forward direction: stamps source_session_id on the target inbound row', async () => {
    // A.S1 emits an outbound a2a to B.
    await routeAgentMessage(
      {
        id: 'msg-from-A-S1',
        platform_id: B,
        content: JSON.stringify({ text: 'hello B' }),
        in_reply_to: null,
      },
      S1,
    );

    const bRows = readInbound(B, SB.id);
    expect(bRows).toHaveLength(1);
    expect(bRows[0].platform_id).toBe(A);
    expect(bRows[0].source_session_id).toBe(S1.id); // <- the return address
  });

  it('reply direction: routes back to the originating session, not the newest', async () => {
    // A.S1 sends to B.
    await routeAgentMessage(
      {
        id: 'msg-from-A-S1',
        platform_id: B,
        content: JSON.stringify({ text: 'ping' }),
        in_reply_to: null,
      },
      S1,
    );

    // Capture the synthetic id the host stamped on B's inbound — that's what
    // B's container would reference as `in_reply_to` when replying.
    const bRows = readInbound(B, SB.id);
    const yId = bRows[0].id;

    // B replies to that message.
    await routeAgentMessage(
      {
        id: 'msg-from-B',
        platform_id: A,
        content: JSON.stringify({ text: 'pong' }),
        in_reply_to: yId,
      },
      SB,
    );

    const s1Rows = readInbound(A, S1.id);
    const s2Rows = readInbound(A, S2.id);

    // The reply lands in S1 (originator) even though S2 is newer.
    expect(s1Rows).toHaveLength(1);
    expect(s1Rows[0].platform_id).toBe(B);
    expect(JSON.parse(s1Rows[0].content).text).toBe('pong');
    expect(s2Rows).toHaveLength(0);
  });

  it('fallback: a2a with no in_reply_to falls through to newest-session lookup', async () => {
    // No prior conversation. B initiates an a2a to A out of the blue.
    await routeAgentMessage(
      {
        id: 'msg-from-B-fresh',
        platform_id: A,
        content: JSON.stringify({ text: 'unsolicited' }),
        in_reply_to: null,
      },
      SB,
    );

    // Newest session wins (current heuristic, preserved).
    const s1Rows = readInbound(A, S1.id);
    const s2Rows = readInbound(A, S2.id);
    expect(s1Rows).toHaveLength(0);
    expect(s2Rows).toHaveLength(1);
  });

  it('peer-affinity fallback: with no in_reply_to, routes to most recent peer-source session', async () => {
    // A.S1 sends to B (establishing affinity: B's last contact from A was via S1).
    await routeAgentMessage(
      {
        id: 'msg-from-A-S1-pre',
        platform_id: B,
        content: JSON.stringify({ text: 'context-establishing' }),
        in_reply_to: null,
      },
      S1,
    );

    // B sends a follow-up but its container forgot to set in_reply_to (e.g.
    // emitted via an MCP tool path that doesn't thread the batch's in_reply_to
    // through). The host should still route this to S1 because S1 is the
    // session most recently in conversation with B — not the chronologically
    // newest session of A.
    await routeAgentMessage(
      {
        id: 'msg-from-B-followup',
        platform_id: A,
        content: JSON.stringify({ text: 'standing by' }),
        in_reply_to: null,
      },
      SB,
    );

    const s1Rows = readInbound(A, S1.id);
    const s2Rows = readInbound(A, S2.id);
    // Affinity wins: reply to S1, not the newer S2.
    expect(s1Rows).toHaveLength(1);
    expect(JSON.parse(s1Rows[0].content).text).toBe('standing by');
    expect(s2Rows).toHaveLength(0);
  });

  it('stale origin fallback: closed origin session falls through to newest active', async () => {
    // A.S1 sends to B, establishing source_session_id = S1.id on B's inbound.
    await routeAgentMessage(
      { id: 'msg-fwd', platform_id: B, content: JSON.stringify({ text: 'hello' }), in_reply_to: null },
      S1,
    );
    const bRows = readInbound(B, SB.id);
    const inboundId = bRows[0].id;

    // Close S1 — simulates session cleanup or channel disconnect.
    updateSession(S1.id, { status: 'closed' });

    // B replies. origin points to S1 (closed), should fall through to S2.
    await routeAgentMessage(
      { id: 'msg-reply-stale', platform_id: A, content: JSON.stringify({ text: 'reply' }), in_reply_to: inboundId },
      SB,
    );

    const s1Rows = readInbound(A, S1.id);
    const s2Rows = readInbound(A, S2.id);
    expect(s1Rows).toHaveLength(0);
    expect(s2Rows).toHaveLength(1);
  });

  it('cross-agent-group guard: origin session belonging to wrong agent group is rejected', async () => {
    // Third agent group C sends to B, stamping source_session_id = SC on B's inbound.
    const C = 'ag-C';
    createAgentGroup({ id: C, name: 'C', folder: 'c', agent_provider: null, created_at: now() });
    const SC: Session = {
      id: 'sess-C',
      agent_group_id: C,
      messaging_group_id: null,
      thread_id: null,
      owner_key: null,
      agent_provider: null,
      status: 'active',
      container_status: 'stopped',
      last_active: null,
      created_at: '2026-03-01T00:00:00.000Z',
    };
    createSession(SC);
    initSessionFolder(C, SC.id);
    createDestination({ agent_group_id: C, local_name: 'b', target_type: 'agent', target_id: B, created_at: now() });

    await routeAgentMessage(
      { id: 'msg-from-C', platform_id: B, content: JSON.stringify({ text: 'from C' }), in_reply_to: null },
      SC,
    );
    const bRows = readInbound(B, SB.id);
    const cInboundId = bRows.find((r) => r.platform_id === C)!.id;

    // B replies to A, but in_reply_to references the C-originated row.
    // Guard rejects (SC belongs to C, not A) → falls through to newest of A.
    await routeAgentMessage(
      {
        id: 'msg-reply-tamper',
        platform_id: A,
        content: JSON.stringify({ text: 'misdirected' }),
        in_reply_to: cInboundId,
      },
      SB,
    );

    const s1Rows = readInbound(A, S1.id);
    const s2Rows = readInbound(A, S2.id);
    expect(s1Rows).toHaveLength(0);
    expect(s2Rows).toHaveLength(1);
  });

  it('in_reply_to referencing a non-a2a row falls through to newest session', async () => {
    // Write a channel message into B's inbound (no source_session_id).
    writeSessionMessage(B, SB.id, {
      id: 'channel-msg-1',
      kind: 'chat',
      timestamp: now(),
      platformId: 'user-123',
      channelType: 'slack',
      threadId: null,
      content: 'hello from slack',
    });

    // B replies to A with in_reply_to pointing to the channel message.
    // source_session_id is null → peer-affinity finds nothing → newest of A.
    await routeAgentMessage(
      {
        id: 'msg-reply-channel',
        platform_id: A,
        content: JSON.stringify({ text: 'response' }),
        in_reply_to: 'channel-msg-1',
      },
      SB,
    );

    const s1Rows = readInbound(A, S1.id);
    const s2Rows = readInbound(A, S2.id);
    expect(s1Rows).toHaveLength(0);
    expect(s2Rows).toHaveLength(1);
  });

  it('self-message is allowed without a destination row', async () => {
    // A targets itself — no agent_destinations row exists for A→A.
    await routeAgentMessage(
      { id: 'self-msg', platform_id: A, content: JSON.stringify({ text: 'self-note' }), in_reply_to: null },
      S1,
    );

    // Lands in S2 (newest active session of A via resolveSession fallback).
    const s2Rows = readInbound(A, S2.id);
    expect(s2Rows).toHaveLength(1);
    expect(JSON.parse(s2Rows[0].content).text).toBe('self-note');
  });

  it('BUG: no volume cap on a2a routing — unbounded ping-pong is allowed (#2063)', async () => {
    // Two agents can exchange unlimited messages with no rate limit or loop
    // detection. This test documents the gap — it should FAIL once #2063 lands.
    const errors: string[] = [];
    for (let i = 0; i < 20; i++) {
      try {
        await routeAgentMessage(
          { id: `ping-${i}`, platform_id: B, content: JSON.stringify({ text: `ping ${i}` }), in_reply_to: null },
          S1,
        );
        await routeAgentMessage(
          { id: `pong-${i}`, platform_id: A, content: JSON.stringify({ text: `pong ${i}` }), in_reply_to: null },
          SB,
        );
      } catch (e) {
        errors.push((e as Error).message);
        break;
      }
    }
    // BUG: all 40 messages go through — no cap, no throttle.
    // Once loop prevention lands, this should throw or reject after a threshold.
    const bRows = readInbound(B, SB.id);
    const s1Rows = readInbound(A, S1.id);
    const s2Rows = readInbound(A, S2.id);
    expect(errors).toHaveLength(0);
    expect(bRows).toHaveLength(20);
    expect(s1Rows.length + s2Rows.length).toBe(20);
  });

  it('hop cap: drops a forward whose chain depth would exceed MAX_A2A_HOPS', async () => {
    // Walk a chain A.S1 → B.SB → A.S1 → B.SB → ... each link using the
    // PREVIOUS link's stamped inbound id as in_reply_to. With MAX_A2A_HOPS=5
    // the 6th forward must be refused — no row appears at the target.
    let lastIdAtA: string | null = null;
    let lastIdAtB: string | null = null;
    // Hop 1: A → B (sourceHops=0 → newHops=1)
    await routeAgentMessage(
      { id: 'h-1', platform_id: B, content: JSON.stringify({ text: '1' }), in_reply_to: null },
      S1,
    );
    lastIdAtB = readInbound(B, SB.id).slice(-1)[0]!.id;
    // Hops 2..5
    for (let n = 2; n <= 5; n++) {
      if (n % 2 === 0) {
        // B → A
        await routeAgentMessage(
          { id: `h-${n}`, platform_id: A, content: JSON.stringify({ text: String(n) }), in_reply_to: lastIdAtB },
          SB,
        );
        // Reply lands in S1 via peer-affinity / source-session-id chain.
        lastIdAtA = readInbound(A, S1.id).slice(-1)[0]!.id;
      } else {
        // A → B
        await routeAgentMessage(
          { id: `h-${n}`, platform_id: B, content: JSON.stringify({ text: String(n) }), in_reply_to: lastIdAtA },
          S1,
        );
        lastIdAtB = readInbound(B, SB.id).slice(-1)[0]!.id;
      }
    }
    expect(readInbound(B, SB.id).length + readInbound(A, S1.id).length).toBe(5);

    // Hop 6 — B → A replying to the just-stamped hops=5 row at B. The
    // sourceHops lookup must return 5; newHops=6 trips the cap and the
    // forward is dropped. No new inbound row appears on either side.
    const beforeB = readInbound(B, SB.id).length;
    const beforeAS1 = readInbound(A, S1.id).length;
    await routeAgentMessage(
      { id: 'h-6', platform_id: A, content: JSON.stringify({ text: '6' }), in_reply_to: lastIdAtB },
      SB,
    );
    expect(readInbound(B, SB.id).length).toBe(beforeB);
    expect(readInbound(A, S1.id).length).toBe(beforeAS1);
  });

  it('file forwarding: copies bytes from source outbox to target inbox', async () => {
    // Place a file in S1's outbox for the message.
    const outboxDir = path.join(sessionDir(A, S1.id), 'outbox', 'msg-with-file');
    fs.mkdirSync(outboxDir, { recursive: true });
    fs.writeFileSync(path.join(outboxDir, 'report.pdf'), 'fake-pdf-bytes');

    await routeAgentMessage(
      {
        id: 'msg-with-file',
        platform_id: B,
        content: JSON.stringify({ text: 'see attached', files: ['report.pdf'] }),
        in_reply_to: null,
      },
      S1,
    );

    const bRows = readInbound(B, SB.id);
    expect(bRows).toHaveLength(1);
    const parsed = JSON.parse(bRows[0].content);
    expect(parsed.attachments).toHaveLength(1);
    expect(parsed.attachments[0].name).toBe('report.pdf');
    expect(parsed.attachments[0].type).toBe('file');

    // Verify actual file bytes were copied to the target inbox.
    const targetPath = path.join(sessionDir(B, SB.id), parsed.attachments[0].localPath);
    expect(fs.existsSync(targetPath)).toBe(true);
    expect(fs.readFileSync(targetPath, 'utf-8')).toBe('fake-pdf-bytes');
  });
});

/**
 * Owner-scoped a2a routing: agents are shared across people, memory is
 * partitioned by `session.owner_key`. Routing must stay within one person —
 * a source session owned by `p2` sending to a target group with both an
 * owner-owned and a p2-owned active session must land in the p2 session.
 */
describe('resolveTargetSession owner-scoping', () => {
  beforeEach(() => {
    if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true });
    fs.mkdirSync(TEST_DIR, { recursive: true });

    const db = initTestDb();
    runMigrations(db);
  });

  afterEach(() => {
    closeDb();
    if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true });
  });

  it('resolveTargetSession picks the session matching the source owner_key', () => {
    const tgt = 'ag-greg';
    createAgentGroup({ id: tgt, name: 'Greg', folder: 'greg', agent_provider: null, created_at: now() });
    // Source agent group + its inbound DB folder (resolveTargetSession opens it).
    createAgentGroup({ id: 'ag-jarvis', name: 'Jarvis', folder: 'jarvis', agent_provider: null, created_at: now() });
    initSessionFolder('ag-jarvis', 's-src');

    createSession({
      id: 's-owner',
      agent_group_id: tgt,
      messaging_group_id: null,
      thread_id: null,
      owner_key: 'sergei',
      agent_provider: null,
      status: 'active',
      container_status: 'stopped',
      last_active: null,
      created_at: now(),
    });
    createSession({
      id: 's-p2',
      agent_group_id: tgt,
      messaging_group_id: null,
      thread_id: null,
      owner_key: 'p2',
      agent_provider: null,
      status: 'active',
      container_status: 'stopped',
      last_active: null,
      created_at: now(),
    });

    const sourceSession = {
      id: 's-src',
      agent_group_id: 'ag-jarvis',
      messaging_group_id: null,
      thread_id: null,
      owner_key: 'p2',
      agent_provider: null,
      status: 'active' as const,
      container_status: 'stopped' as const,
      last_active: null,
      created_at: now(),
    };
    const picked = resolveTargetSession(
      { id: 'm1', platform_id: tgt, content: '{}', in_reply_to: null },
      sourceSession,
      tgt,
    );
    expect(picked.owner_key).toBe('p2');
    expect(picked.id).toBe('s-p2');
  });

  it('creates a fresh owner-stamped session when the target group has no session for this owner', () => {
    const tgt = 'ag-greg-fresh';
    createAgentGroup({ id: tgt, name: 'GregF', folder: 'greg-fresh', agent_provider: null, created_at: now() });
    // Source agent group + its inbound DB folder (resolveTargetSession opens it).
    createAgentGroup({ id: 'ag-jarvis', name: 'Jarvis', folder: 'jarvis', agent_provider: null, created_at: now() });
    initSessionFolder('ag-jarvis', 's-src2');

    // Only a foreign-owner (sergei) active session exists in the target group.
    createSession({
      id: 's-owner-only',
      agent_group_id: tgt,
      messaging_group_id: null,
      thread_id: null,
      owner_key: 'sergei',
      agent_provider: null,
      status: 'active',
      container_status: 'stopped',
      last_active: null,
      created_at: now(),
    });

    const sourceSession = {
      id: 's-src2',
      agent_group_id: 'ag-jarvis',
      messaging_group_id: null,
      thread_id: null,
      owner_key: 'p2',
      agent_provider: null,
      status: 'active' as const,
      container_status: 'stopped' as const,
      last_active: null,
      created_at: now(),
    };

    // No owned session exists for p2 → must create a fresh session, never
    // adopt the sergei-owned session.
    const picked = resolveTargetSession(
      { id: 'm2', platform_id: tgt, content: '{}', in_reply_to: null },
      sourceSession,
      tgt,
    );

    expect(picked.owner_key).toBe('p2');
    expect(picked.id).not.toBe('s-owner-only');
    // All session dirs are under TEST_DIR (DATA_DIR mock), cleaned by afterEach.
  });
});

describe('stampSenderIdentity', () => {
  beforeEach(() => {
    const db = initTestDb();
    runMigrations(db);
    createAgentGroup({ id: 'payne', name: 'Майор Пейн', folder: 'payne', agent_provider: null, created_at: now() });
  });

  afterEach(() => {
    closeDb();
  });

  it('stamps the source agent canonical name + folder onto JSON content', () => {
    const out = stampSenderIdentity('{"action":"workout_done","type":"Ноги"}', 'payne');
    expect(JSON.parse(out)).toEqual({
      action: 'workout_done',
      type: 'Ноги',
      sender: 'Майор Пейн',
      senderId: 'payne',
    });
  });

  it('never clobbers an existing sender (system notes set their own)', () => {
    const out = stampSenderIdentity('{"text":"hi","sender":"system","senderId":"system"}', 'payne');
    expect(JSON.parse(out).sender).toBe('system');
    expect(JSON.parse(out).senderId).toBe('system');
  });

  it('treats an empty or null sender as unset and stamps it', () => {
    const out = stampSenderIdentity('{"text":"hi","sender":"","senderId":null}', 'payne');
    expect(JSON.parse(out).sender).toBe('Майор Пейн');
    expect(JSON.parse(out).senderId).toBe('payne');
  });

  it('returns non-JSON content unchanged', () => {
    expect(stampSenderIdentity('plain text', 'payne')).toBe('plain text');
  });

  it('returns non-object JSON content unchanged', () => {
    expect(stampSenderIdentity('"just a string"', 'payne')).toBe('"just a string"');
  });

  // Contract test, NOT branch coverage for the `Array.isArray` guard: JSON.stringify
  // drops non-index properties assigned to an array, so this passes with or without
  // that guard. It still catches a rewrite that mangles arrays into objects.
  it('passes a top-level JSON array through unchanged', () => {
    expect(stampSenderIdentity('[1,2,3]', 'payne')).toBe('[1,2,3]');
  });

  it('returns content unchanged when the source group is unknown', () => {
    expect(stampSenderIdentity('{"text":"hi"}', 'ghost')).toBe('{"text":"hi"}');
  });

  it('falls back to the folder id when the group name is empty', () => {
    createAgentGroup({ id: 'noname', name: '', folder: 'noname', agent_provider: null, created_at: now() });
    expect(JSON.parse(stampSenderIdentity('{"text":"hi"}', 'noname')).sender).toBe('noname');
  });
});

/**
 * Layer 2 — the authoritative kind gate.
 *
 * routeAgentMessage is the single chokepoint every a2a message crosses, no
 * matter which emit path produced it. This layer should almost never fire in
 * steady state: the container gate (Layer 1) catches essentially everything
 * in-turn with better context. Its value is that the declaration becomes
 * BINDING — an emit path that skips poll-loop (the MCP send_message tool,
 * which writes messages_out from a separate subprocess) is still checked.
 *
 * A rejected message is bounced into the SENDER's own inbound as a system
 * self-note rather than dropped: dying silently in the retry path is the
 * "cuts live traffic" failure the owner explicitly ruled out.
 */
describe('routeAgentMessage a2a kind gate (layer 2)', () => {
  const A = 'ag-A';
  const B = 'ag-B';
  let SA: Session;
  let SB: Session;

  /** Author `<AGENTS_DIR>/<folder>/agent.json` — the TARGET's own descriptor. */
  function writeDescriptor(folder: string, descriptor: unknown): void {
    const dir = path.join(TEST_AGENTS_DIR, folder);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'agent.json'), JSON.stringify(descriptor));
  }

  beforeEach(() => {
    if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true });
    fs.mkdirSync(TEST_DIR, { recursive: true });

    const db = initTestDb();
    runMigrations(db);

    createAgentGroup({ id: A, name: 'Джарвис', folder: 'a', agent_provider: null, created_at: now() });
    createAgentGroup({ id: B, name: 'Майор Пейн', folder: 'b', agent_provider: null, created_at: now() });

    SA = {
      id: 'sess-A',
      agent_group_id: A,
      messaging_group_id: null,
      thread_id: null,
      owner_key: null,
      agent_provider: null,
      status: 'active',
      container_status: 'stopped',
      last_active: null,
      created_at: '2026-01-01T00:00:00.000Z',
    };
    SB = {
      id: 'sess-B',
      agent_group_id: B,
      messaging_group_id: null,
      thread_id: null,
      owner_key: null,
      agent_provider: null,
      status: 'active',
      container_status: 'stopped',
      last_active: null,
      created_at: '2026-01-01T00:00:00.000Z',
    };
    createSession(SA);
    createSession(SB);
    initSessionFolder(A, SA.id);
    initSessionFolder(B, SB.id);

    createDestination({ agent_group_id: A, local_name: 'b', target_type: 'agent', target_id: B, created_at: now() });
    createDestination({ agent_group_id: A, local_name: 'a', target_type: 'agent', target_id: A, created_at: now() });
  });

  afterEach(() => {
    closeDb();
    if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true });
  });

  const send = (content: object) =>
    routeAgentMessage({ id: 'm1', platform_id: B, content: JSON.stringify(content), in_reply_to: null }, SA);

  describe('armed target (B declares set_log)', () => {
    beforeEach(() => {
      writeDescriptor('b', { role: 'тренер', a2a_in: { set_log: 'лог подхода' } });
    });

    it('does not route an undeclared kind', async () => {
      await send({ text: '{}', kind: 'bogus' });
      expect(readInbound(B, SB.id)).toHaveLength(0);
    });

    it('bounces the rejection into the SENDER own inbound as a system self-note', async () => {
      await send({ text: '{}', kind: 'bogus' });

      const back = readInbound(A, SA.id);
      expect(back).toHaveLength(1);
      // Addressed from the sender to itself — the formatter renders this
      // agent="system", which is why the `system` folder is reserved.
      expect(back[0].platform_id).toBe(A);
      expect(back[0].channel_type).toBe('agent');
      const parsed = JSON.parse(back[0].content);
      expect(parsed.sender).toBe('system');
      expect(parsed.senderId).toBe('system');
      // The note must name the offence and the target, or the agent cannot fix it.
      expect(parsed.text).toContain('bogus');
      expect(parsed.text).toContain('Майор Пейн');
      expect(parsed.text).toContain('set_log');
    });

    it('routes a declared kind', async () => {
      // Guards the inverse mutation: a gate that bounced everything once armed
      // would pass the tests above while cutting all live traffic.
      await send({ text: '{"reps":8}', kind: 'set_log' });
      expect(readInbound(B, SB.id)).toHaveLength(1);
      expect(readInbound(A, SA.id)).toHaveLength(0);
    });

    it('rejects a JSON-object body carrying no kind — the MCP send_message path', async () => {
      // send_message writes {text} with no kind at all. That is exactly how a
      // structured payload sails through as prose, so it must bounce.
      await send({ text: '{"reps":8}' });
      expect(readInbound(B, SB.id)).toHaveLength(0);
      expect(JSON.parse(readInbound(A, SA.id)[0].content).text).toContain('kind');
    });

    it('routes prose carrying no kind', async () => {
      // `text` is legal without being declared. Without this, the test above
      // would also pass a gate that bounced every kind-less message.
      await send({ text: 'как продвигается?' });
      expect(readInbound(B, SB.id)).toHaveLength(1);
    });

    it('routes non-JSON content untouched', async () => {
      // A bare string has no envelope to judge; Layer 1 already saw it.
      await routeAgentMessage({ id: 'm1', platform_id: B, content: 'plain text', in_reply_to: null }, SA);
      expect(readInbound(B, SB.id)).toHaveLength(1);
    });

    it('never gates a host-authored system note', async () => {
      // Host notes (approvals, restarts, bounces) are not agent protocol and
      // must always land. Today no system note reaches this function — bounces
      // are written straight to inbound, which is the real reason a bounce
      // cannot bounce — so this pins the exemption as the second guard rather
      // than reproducing a live path. Killable: drop the exemption and the
      // illegal kind below bounces instead of routing.
      await routeAgentMessage(
        {
          id: 'm1',
          platform_id: B,
          content: JSON.stringify({ text: '{}', kind: 'bogus', sender: 'system' }),
          in_reply_to: null,
        },
        SA,
      );
      expect(readInbound(B, SB.id)).toHaveLength(1);
      expect(readInbound(A, SA.id)).toHaveLength(0);
    });
  });

  it('routes normally when the target has no descriptor (gate disarmed)', async () => {
    // SHIP-INERT. No agent.json exists anywhere in the wild, so this is the
    // live behaviour of every message today.
    //
    // Honest note on killability: deleting the gate would NOT fail this test.
    // It kills a different mutation — normalizing a missing descriptor to `[]`
    // instead of null, which would bounce every structured a2a message in
    // production. Verified by running that mutation.
    await send({ text: '{"reps":8}', kind: 'anything_at_all' });
    expect(readInbound(B, SB.id)).toHaveLength(1);
    expect(readInbound(A, SA.id)).toHaveLength(0);
  });

  it('routes normally when the target descriptor is malformed (fail open)', async () => {
    // A typo in agent.json must not bounce an agent's entire inbox.
    fs.mkdirSync(path.join(TEST_AGENTS_DIR, 'b'), { recursive: true });
    fs.writeFileSync(path.join(TEST_AGENTS_DIR, 'b', 'agent.json'), '{ this is not json');
    await send({ text: '{}', kind: 'bogus' });
    expect(readInbound(B, SB.id)).toHaveLength(1);
  });

  it('bounces a target that declares no kinds when the body is structured', async () => {
    // `[]` is NOT null: descriptor present, declares nothing → text-only, ARMED.
    writeDescriptor('b', { role: 'аналитик' });
    await send({ text: '{}', kind: 'set_log' });
    expect(readInbound(B, SB.id)).toHaveLength(0);
    expect(readInbound(A, SA.id)).toHaveLength(1);
  });
});
