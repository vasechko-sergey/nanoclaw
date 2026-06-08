// End-to-end integration scenarios for ios-app protocol v2.
//
// Each `describe` block is one of the 11 scenarios from the v2 plan
// (docs/ios-app-protocol-v2-plan.md, task 6.2). They exercise the full
// WsHandler + InboundDispatcher + OutboundQueue + ContextBridge stack
// against a live ws server via the harness — no module is mocked.
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { randomUUID } from 'node:crypto';
import { WebSocket } from 'ws';
import { startTestServer, type Harness, type HarnessReceivedEvent } from './testing/harness.js';
import { CLOSE_CODES } from './ws-handler.js';
import { MAX_QUEUE_PER_DEVICE } from './types.js';

let h: Harness;
beforeEach(async () => {
  h = await startTestServer();
});
afterEach(async () => {
  await h.close();
});

const makeMessageEnvelope = (over: Record<string, unknown> = {}) => ({
  v: 2 as const,
  kind: 'data',
  type: 'message',
  id: randomUUID(),
  seq: 1,
  ts: new Date().toISOString(),
  payload: { thread_id: 'c-1', text: 'hi' },
  ...over,
});

const makePingEnvelope = (nonce: string) => ({
  v: 2 as const,
  kind: 'control',
  type: 'ping',
  id: randomUUID(),
  seq: null,
  ts: new Date().toISOString(),
  payload: { nonce },
});

const makeContextResponseEnvelope = (request_id: string, seq: number, data: Record<string, unknown>) => ({
  v: 2 as const,
  kind: 'control',
  type: 'context_response',
  id: randomUUID(),
  seq,
  ts: new Date().toISOString(),
  payload: { request_id, data },
});

async function drainAllIncoming(ws: WebSocket, count: number): Promise<any[]> {
  const out: any[] = [];
  for (let i = 0; i < count; i++) {
    out.push(await h.expectIncoming(ws));
  }
  return out;
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

// ─── Scenario 1: happy path ───────────────────────────────────────────────
describe('Scenario 1: happy path', () => {
  it('round-trips a user message and a server-pushed agent reply', async () => {
    const ws = await h.connectAuthed();

    // Client → server.
    const userEnv = makeMessageEnvelope({ payload: { thread_id: 'c-1', text: 'hello agent' } });
    h.send(ws, userEnv);
    const ack = await h.expectIncoming(ws);
    expect(ack.kind).toBe('ack');
    expect(ack.type).toBe('ack');
    expect(ack.payload.id).toBe(userEnv.id);
    expect(ack.payload.seq).toBe(1);

    const userMsgs = h.agent.received.filter((m) => m.kind === 'user_message');
    expect(userMsgs).toHaveLength(1);

    // Server → client (agent reply).
    const replyId = randomUUID();
    h.handler.sendEnvelopeToDevice(h.platformId, {
      kind: 'data',
      type: 'message',
      id: replyId,
      payload: { thread_id: 'c-1', text: 'hi back' },
    });
    const reply = await h.expectIncoming(ws);
    expect(reply.kind).toBe('data');
    expect(reply.type).toBe('message');
    expect(reply.id).toBe(replyId);
    expect(reply.seq).toBe(1);
    expect(reply.payload.text).toBe('hi back');

    ws.close();
  });
});

// ─── Scenario 2: reconnect mid-send ──────────────────────────────────────
describe('Scenario 2: reconnect mid-send', () => {
  it('client retransmits same id+seq after reconnect; server acks twice, agent sees once', async () => {
    const ws1 = await h.connectAuthed();

    // Client sends, sees ack but pretends it didn't (simulate by closing right after send).
    const sharedId = randomUUID();
    const env = makeMessageEnvelope({ id: sharedId, seq: 4, payload: { thread_id: 'c-1', text: 'mid-flight' } });
    h.send(ws1, env);
    const ack1 = await h.expectIncoming(ws1);
    expect(ack1.type).toBe('ack');
    ws1.close();

    // Reconnect, claiming we haven't seen any inbound from server (still 0).
    const ws2 = await h.connectAuthed({ lastSeenInbound: 0 });
    // Client retransmits the same envelope.
    h.send(ws2, env);
    const ack2 = await h.expectIncoming(ws2);
    expect(ack2.type).toBe('ack');
    expect(ack2.payload.id).toBe(sharedId);

    // Dedup: agent only saw the message once.
    const userMsgs = h.agent.received.filter((m) => m.kind === 'user_message');
    expect(userMsgs).toHaveLength(1);

    ws2.close();
  });
});

// ─── Scenario 3: reconnect mid-receive ────────────────────────────────────
describe('Scenario 3: reconnect mid-receive', () => {
  it('queue contains seqs 10–12; client connects with cursor=9; flush happens in order', async () => {
    h.db.upsertDevice(h.platformId, {});

    // Pre-fill device's inbound seq to 9 so the next enqueue allocates seq 10.
    h.db.raw.prepare(`UPDATE devices SET last_emitted_inbound_seq = 9 WHERE platform_id = ?`).run(h.platformId);

    const ids = [randomUUID(), randomUUID(), randomUUID()];
    for (const id of ids) {
      h.handler.sendEnvelopeToDevice(h.platformId, {
        kind: 'data',
        type: 'message',
        id,
        payload: { thread_id: 'c-1', text: `seq=${id.slice(0, 4)}` },
      });
    }

    const rows = h.queue.list(h.platformId);
    expect(rows.map((r) => r.seq)).toEqual([10, 11, 12]);

    const ws = await h.connectAuthed({ lastSeenInbound: 9 });
    const drained = await drainAllIncoming(ws, 3);

    expect(drained.map((e) => e.seq)).toEqual([10, 11, 12]);
    expect(drained.map((e) => e.id)).toEqual(ids);

    ws.close();
  });
});

// ─── Scenario 4: dedup by id ──────────────────────────────────────────────
describe('Scenario 4: dedup by id', () => {
  it('same envelope id sent twice → two acks, agent sees one row', async () => {
    const ws = await h.connectAuthed();
    const env = makeMessageEnvelope({ id: randomUUID(), seq: 1 });

    h.send(ws, env);
    const ack1 = await h.expectIncoming(ws);
    expect(ack1.type).toBe('ack');

    h.send(ws, env);
    const ack2 = await h.expectIncoming(ws);
    expect(ack2.type).toBe('ack');

    expect(h.agent.received.filter((m) => m.kind === 'user_message')).toHaveLength(1);
    const dedup = h.db.raw
      .prepare(`SELECT COUNT(*) AS n FROM inbound_dedup WHERE platform_id = ?`)
      .get(h.platformId) as { n: number };
    expect(dedup.n).toBe(1);

    ws.close();
  });
});

// ─── Scenario 5: queue overflow ───────────────────────────────────────────
describe('Scenario 5: queue overflow', () => {
  it('enqueues MAX+5 while offline → keeps newest MAX, drops oldest 5 silently', async () => {
    h.db.upsertDevice(h.platformId, {});

    const total = MAX_QUEUE_PER_DEVICE + 5;
    const ids: string[] = [];
    for (let i = 0; i < total; i++) {
      const id = randomUUID();
      ids.push(id);
      h.handler.sendEnvelopeToDevice(h.platformId, {
        kind: 'data',
        type: 'message',
        id,
        payload: { thread_id: 'c-1', text: `msg-${i}` },
      });
    }

    const rows = h.queue.list(h.platformId);
    expect(rows).toHaveLength(MAX_QUEUE_PER_DEVICE);

    // Oldest 5 IDs are gone; newest MAX are present in order.
    const remainingIds = new Set(rows.map((r) => r.id));
    for (let i = 0; i < 5; i++) {
      expect(remainingIds.has(ids[i])).toBe(false);
    }
    for (let i = 5; i < total; i++) {
      expect(remainingIds.has(ids[i])).toBe(true);
    }

    // Seq numbers should be the last MAX consecutive ones (overflow doesn't reuse seqs).
    const seqs = rows.map((r) => r.seq);
    expect(seqs[0]).toBe(6);
    expect(seqs[seqs.length - 1]).toBe(total);

    // Client connects with cursor=0 and drains exactly MAX rows.
    const ws = await h.connectAuthed({ lastSeenInbound: 0 });
    const drained = await drainAllIncoming(ws, MAX_QUEUE_PER_DEVICE);
    expect(drained).toHaveLength(MAX_QUEUE_PER_DEVICE);
    expect(drained[0].seq).toBe(6);
    expect(drained[drained.length - 1].seq).toBe(total);

    ws.close();
  });
});

// ─── Scenario 6: context request happy ───────────────────────────────────
describe('Scenario 6: context request happy path', () => {
  it('agent requests context → client receives + replies → agent observes', async () => {
    const ws = await h.connectAuthed();

    const requestId = randomUUID();
    h.bridge.handleAgentRequest({
      session_id: 'sess-1',
      request_id: requestId,
      fields: ['device'],
      params: {},
      expires_at_ms: Date.now() + 10_000,
    });

    // Client should receive a context_request envelope.
    const ctxReq = await h.expectIncoming(ws);
    expect(ctxReq.kind).toBe('control');
    expect(ctxReq.type).toBe('context_request');
    expect(ctxReq.payload.request_id).toBe(requestId);
    expect(ctxReq.payload.fields).toEqual(['device']);

    // Client replies with context_response.
    const respSeq = 2;
    const resp = makeContextResponseEnvelope(requestId, respSeq, {
      device: { model: 'iPhone 15', os: 'iOS 17' },
    });
    h.send(ws, resp);
    const ack = await h.expectIncoming(ws);
    expect(ack.type).toBe('ack');

    // Agent observed context_response.
    const ctxResponses = h.agent.received.filter((m) => m.kind === 'context_response');
    expect(ctxResponses).toHaveLength(1);

    // Pending request row was deleted.
    const remaining = h.db.raw
      .prepare(`SELECT COUNT(*) AS n FROM pending_context_requests WHERE request_id = ?`)
      .get(requestId) as { n: number };
    expect(remaining.n).toBe(0);

    ws.close();
  });
});

// ─── Scenario 7: context request timeout ─────────────────────────────────
describe('Scenario 7: context request timeout', () => {
  it('client never replies; sweep emits synthetic timeout response', async () => {
    const ws = await h.connectAuthed();

    const requestId = randomUUID();
    const expiresAt = Date.now() + 100;
    h.bridge.handleAgentRequest({
      session_id: 'sess-1',
      request_id: requestId,
      fields: ['device'],
      params: {},
      expires_at_ms: expiresAt,
    });

    // Drain the context_request envelope so it doesn't confuse subsequent expects.
    const ctxReq = await h.expectIncoming(ws);
    expect(ctxReq.type).toBe('context_request');

    // Wait for expiry then sweep.
    await sleep(200);
    h.bridge.sweepExpired();

    const synthetic = h.agent.received.filter((m) => m.kind === 'context_response_synthetic') as Array<
      HarnessReceivedEvent & { request_id: string; errors?: Record<string, string> }
    >;
    expect(synthetic).toHaveLength(1);
    expect(synthetic[0].request_id).toBe(requestId);
    expect(synthetic[0].errors).toEqual({ timeout: 'device offline / timeout' });

    const remaining = h.db.raw
      .prepare(`SELECT COUNT(*) AS n FROM pending_context_requests WHERE request_id = ?`)
      .get(requestId) as { n: number };
    expect(remaining.n).toBe(0);

    ws.close();
  });
});

// ─── Scenario 8: per-session scope reject ────────────────────────────────
describe('Scenario 8: per-session scope reject', () => {
  it('agent requests context for session with no wired device → synthetic scope error, no ws send', async () => {
    // Build a one-off bridge whose resolver returns null.
    const sends: unknown[] = [];
    const synthetic: Array<{ session_id: string; request_id: string; errors?: Record<string, string> }> = [];

    const { ContextBridge } = await import('./context-bridge.js');
    const isolatedBridge = new ContextBridge({
      db: h.db,
      resolvePlatformForSession: () => null,
      sendEnvelopeToDevice: (_pid, env) => sends.push(env),
      writeInboundContextResponse: (input) => synthetic.push(input),
    });

    const requestId = randomUUID();
    isolatedBridge.handleAgentRequest({
      session_id: 'sess-unwired',
      request_id: requestId,
      fields: ['device'],
      params: {},
      expires_at_ms: Date.now() + 10_000,
    });

    expect(sends).toHaveLength(0);
    expect(synthetic).toHaveLength(1);
    expect(synthetic[0].request_id).toBe(requestId);
    expect(synthetic[0].errors).toEqual({ scope: 'no ios-app device wired' });

    // No pending row was created.
    const remaining = h.db.raw
      .prepare(`SELECT COUNT(*) AS n FROM pending_context_requests WHERE request_id = ?`)
      .get(requestId) as { n: number };
    expect(remaining.n).toBe(0);
  });
});

// ─── Scenario 9: protocol violation closes socket ────────────────────────
describe('Scenario 9: protocol violation closes socket', () => {
  it('client sends v=1 frame → server closes with 4002 protocol_violation', async () => {
    const ws = await h.connectRaw();
    ws.send(JSON.stringify({ v: 1, kind: 'data' }));
    const code = await h.expectClose(ws);
    expect(code).toBe(CLOSE_CODES.protocol_violation);
  });
});

// ─── Scenario 10: superseded socket ──────────────────────────────────────
describe('Scenario 10: superseded socket', () => {
  it('second connect with same token closes A with 4004; B remains live', async () => {
    const ws1 = await h.connectAuthed();
    const ws2 = await h.connectAuthed();

    const code = await h.expectClose(ws1);
    expect(code).toBe(CLOSE_CODES.superseded);
    expect(ws2.readyState).toBe(WebSocket.OPEN);

    // B is fully functional.
    const env = makeMessageEnvelope({ seq: 1 });
    h.send(ws2, env);
    const ack = await h.expectIncoming(ws2);
    expect(ack.type).toBe('ack');

    ws2.close();
  });
});

// ─── Scenario 12: workout bridge — set_log → workout_event ───────────────
describe('Scenario 12: workout bridge — set_log routes as system inbound', () => {
  const makeSetLogEnvelope = (over: Record<string, unknown> = {}) => ({
    v: 2 as const,
    kind: 'data',
    type: 'set_log',
    id: randomUUID(),
    seq: 1,
    ts: new Date().toISOString(),
    payload: {
      workout_id: '01J6Z8W3K2N5A7B9C1D3E5F7G9',
      exercise_slug: 'incline-db-press',
      set_idx: 0,
      reps: 10,
      weight: 22.5,
      reps_in_reserve: 3,
      ts: new Date().toISOString(),
      agent_id: 'payne',
    },
    ...over,
  });

  it('routes set_log envelope into Payne session as workout_event subtype', async () => {
    const ws = await h.connectAuthed();

    const env = makeSetLogEnvelope();
    h.send(ws, env);
    const ack = await h.expectIncoming(ws);
    expect(ack.type).toBe('ack');
    expect(ack.payload.id).toBe(env.id);

    // Bridge wrote one system message tagged 'workout'.
    expect(h.agent.systemWrites).toHaveLength(1);
    const w = h.agent.systemWrites[0];
    expect(w.session_id).toBe('sess-1');
    expect(w.tag).toBe('workout');
    const body = JSON.parse(w.text);
    expect(body.event).toBe('set_log');
    expect(body.payload.exercise_slug).toBe('incline-db-press');
    expect(body.payload.reps_in_reserve).toBe(3);
    expect(body.payload.weight).toBe(22.5);

    // set_log must NOT have fired the chat-style onUserMessage path.
    const userMsgs = h.agent.received.filter((m) => m.kind === 'user_message');
    expect(userMsgs).toHaveLength(0);

    ws.close();
  });

  it('dedups repeated set_log by id — single workout_event write', async () => {
    const ws = await h.connectAuthed();
    const env = makeSetLogEnvelope();

    h.send(ws, env);
    const ack1 = await h.expectIncoming(ws);
    expect(ack1.type).toBe('ack');

    h.send(ws, env);
    const ack2 = await h.expectIncoming(ws);
    expect(ack2.type).toBe('ack');

    expect(h.agent.systemWrites).toHaveLength(1);

    ws.close();
  });
});

// ─── Scenario 11: ping isolation under load ──────────────────────────────
describe('Scenario 11: ping isolation under load', () => {
  it('50 ping rounds interleaved with agent pushes → no ping/pong in agent or dedup/queue', async () => {
    const ws = await h.connectAuthed();

    const pushIds: string[] = [];
    const PING_COUNT = 50;

    // Interleave: ping → pong → push agent reply.
    for (let i = 0; i < PING_COUNT; i++) {
      const nonce = `n-${i}`;
      h.send(ws, makePingEnvelope(nonce));
      const pong = await h.expectIncoming(ws);
      expect(pong.type).toBe('pong');
      expect(pong.payload.nonce).toBe(nonce);

      const id = randomUUID();
      pushIds.push(id);
      h.handler.sendEnvelopeToDevice(h.platformId, {
        kind: 'data',
        type: 'message',
        id,
        payload: { thread_id: 'c-1', text: `push-${i}` },
      });
      const pushed = await h.expectIncoming(ws);
      expect(pushed.type).toBe('message');
      expect(pushed.id).toBe(id);
    }

    // No ping/pong leaked into the agent.
    const stray = h.agent.received.filter(
      (m: any) => m.envelope && (m.envelope.type === 'ping' || m.envelope.type === 'pong'),
    );
    expect(stray).toHaveLength(0);
    // Agent received zero inbound events of any kind — ping isolation.
    expect(h.agent.received).toHaveLength(0);

    // No ping rows in inbound_dedup.
    const dedupRows = h.db.raw.prepare(`SELECT id FROM inbound_dedup WHERE platform_id = ?`).all(h.platformId);
    expect(dedupRows).toHaveLength(0);

    // outbound_queue holds only the agent pushes (pongs have null seq, no row).
    const queueRows = h.queue.list(h.platformId);
    expect(queueRows).toHaveLength(PING_COUNT);
    const queueIds = new Set(queueRows.map((r) => r.id));
    for (const id of pushIds) expect(queueIds.has(id)).toBe(true);

    ws.close();
  });
});
