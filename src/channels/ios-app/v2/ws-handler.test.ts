import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { randomUUID } from 'node:crypto';
import { WebSocket } from 'ws';
import { startTestServer, type Harness } from './testing/harness.js';
import { CLOSE_CODES } from './ws-handler.js';

const MSG_UUID = '11111111-1111-4111-8111-111111111111';

function authEnv(token: string, lastSeen = 0, capabilities: string[] = []) {
  return {
    v: 2,
    kind: 'control',
    type: 'auth',
    id: randomUUID(),
    seq: null,
    ts: new Date().toISOString(),
    payload: {
      token,
      last_seen_inbound_seq: lastSeen,
      capabilities,
    },
  };
}

function messageEnv(seq = 1, id = MSG_UUID, text = 'hi') {
  return {
    v: 2,
    kind: 'data',
    type: 'message',
    id,
    seq,
    ts: new Date().toISOString(),
    payload: { thread_id: 'thr', text },
  };
}

describe('WsHandler', () => {
  let h: Harness;
  beforeEach(async () => {
    h = await startTestServer();
  });
  afterEach(async () => {
    await h.close();
  });

  it('completes handshake: auth → auth_ok with last_seen_outbound_seq=0', async () => {
    const ws = await h.connectRaw();
    h.send(ws, authEnv(h.validToken));
    const env = await h.expectIncoming(ws);
    expect(env.v).toBe(2);
    expect(env.kind).toBe('control');
    expect(env.type).toBe('auth_ok');
    expect(env.seq).toBeNull();
    expect(env.payload.last_seen_outbound_seq).toBe(0);
    expect(typeof env.payload.server_time).toBe('string');
    ws.close();
  });

  it('persists device row on successful auth', async () => {
    const ws = await h.connectAuthed({ capabilities: ['camera', 'mic'] });
    const dev = h.db.getDevice(h.platformId);
    expect(dev).toBeDefined();
    expect(JSON.parse(dev!.capabilities_json!)).toEqual(['camera', 'mic']);
    ws.close();
  });

  it('rejects unparseable frames with close 4002 protocol_violation', async () => {
    const ws = await h.connectRaw();
    ws.send(JSON.stringify({ v: 1, hello: 'world' }));
    const code = await h.expectClose(ws);
    expect(code).toBe(CLOSE_CODES.protocol_violation);
  });

  it('rejects non-auth first frame with close 4003', async () => {
    const ws = await h.connectRaw();
    h.send(ws, messageEnv());
    const code = await h.expectClose(ws);
    expect(code).toBe(CLOSE_CODES.auth_failed);
  });

  it('rejects invalid token with close 4003', async () => {
    const ws = await h.connectRaw();
    h.send(ws, authEnv('not-the-token'));
    const code = await h.expectClose(ws);
    expect(code).toBe(CLOSE_CODES.auth_failed);
  });

  it('acks a user message and dispatches it to the agent exactly once', async () => {
    const ws = await h.connectAuthed();
    h.send(ws, messageEnv(1));
    const ack = await h.expectIncoming(ws);
    expect(ack.type).toBe('ack');
    expect(ack.payload.id).toBe(MSG_UUID);
    expect(ack.payload.seq).toBe(1);
    expect(h.agent.received.filter((r) => r.kind === 'user_message')).toHaveLength(1);
  });

  it('dedups: same envelope twice → two acks, agent sees once', async () => {
    const ws = await h.connectAuthed();
    h.send(ws, messageEnv(1));
    const ack1 = await h.expectIncoming(ws);
    expect(ack1.type).toBe('ack');
    h.send(ws, messageEnv(1));
    const ack2 = await h.expectIncoming(ws);
    expect(ack2.type).toBe('ack');
    expect(h.agent.received.filter((r) => r.kind === 'user_message')).toHaveLength(1);
  });

  it('drains queued outbound rows on connect when client cursor is behind', async () => {
    // Server enqueued a row for the device before the device connects.
    h.db.upsertDevice(h.platformId, {});
    h.queue.enqueue(h.platformId, {
      id: '22222222-2222-4222-8222-222222222222',
      kind: 'data',
      type: 'message',
      payload: { thread_id: 'thr', text: 'hello from server' },
    });
    const ws = await h.connectAuthed({ lastSeenInbound: 0 });
    const drained = await h.expectIncoming(ws);
    expect(drained.type).toBe('message');
    expect(drained.id).toBe('22222222-2222-4222-8222-222222222222');
    expect(drained.seq).toBe(1);
    expect(drained.payload.text).toBe('hello from server');
    ws.close();
  });

  it('ackUpTo on auth drops rows the client has already seen', async () => {
    h.db.upsertDevice(h.platformId, {});
    h.queue.enqueue(h.platformId, {
      id: randomUUID(),
      kind: 'data',
      type: 'message',
      payload: { thread_id: 'thr', text: 'old' },
    });
    h.queue.enqueue(h.platformId, {
      id: '33333333-3333-4333-8333-333333333333',
      kind: 'data',
      type: 'message',
      payload: { thread_id: 'thr', text: 'new' },
    });
    expect(h.queue.list(h.platformId)).toHaveLength(2);
    // Client says it has acked up to seq=1 → row #1 dropped, row #2 drained.
    const ws = await h.connectAuthed({ lastSeenInbound: 1 });
    const drained = await h.expectIncoming(ws);
    expect(drained.seq).toBe(2);
    expect(drained.id).toBe('33333333-3333-4333-8333-333333333333');
    expect(h.queue.list(h.platformId)).toHaveLength(1);
    ws.close();
  });

  it('superseded socket: second connect closes the first with 4004', async () => {
    const ws1 = await h.connectAuthed();
    const ws2 = await h.connectAuthed();
    const code = await h.expectClose(ws1);
    expect(code).toBe(CLOSE_CODES.superseded);
    expect(ws2.readyState).toBe(WebSocket.OPEN);
    ws2.close();
  });

  it('sendEnvelopeToDevice persists + pushes to a live socket', async () => {
    const ws = await h.connectAuthed();
    const id = '44444444-4444-4444-8444-444444444444';
    h.handler.sendEnvelopeToDevice(h.platformId, {
      kind: 'data',
      type: 'message',
      id,
      payload: { thread_id: 'thr', text: 'pushed' },
    });
    const env = await h.expectIncoming(ws);
    expect(env.type).toBe('message');
    expect(env.id).toBe(id);
    expect(env.seq).toBe(1);
    expect(env.payload.text).toBe('pushed');
    expect(h.queue.list(h.platformId)).toHaveLength(1);
    ws.close();
  });

  it('sendEnvelopeToDevice persists even when device is offline', async () => {
    h.db.upsertDevice(h.platformId, {});
    const id = '55555555-5555-4555-8555-555555555555';
    h.handler.sendEnvelopeToDevice(h.platformId, {
      kind: 'data',
      type: 'message',
      id,
      payload: { thread_id: 'thr', text: 'queued' },
    });
    // Now the device connects with lastSeen=0 and should drain it.
    const ws = await h.connectAuthed({ lastSeenInbound: 0 });
    const env = await h.expectIncoming(ws);
    expect(env.id).toBe(id);
    expect(env.seq).toBe(1);
    ws.close();
  });

  it('drained frame carries the enqueue created_at as ts, not the send time', async () => {
    // Regression: an offline-queued reply drained late must keep its authored
    // timestamp so the iOS client (orders chat by `ts`) doesn't sort it after
    // newer messages.
    h.db.upsertDevice(h.platformId, {});
    const id = '66666666-6666-4666-8666-666666666666';
    h.queue.enqueue(h.platformId, {
      id,
      kind: 'data',
      type: 'message',
      payload: { thread_id: 'thr', text: 'stable ts' },
    });
    // Backdate the row so the send-time (now) cannot coincide with created_at.
    const authoredMs = 1_700_000_000_000; // 2023-11-14T22:13:20.000Z
    h.db.raw.prepare('UPDATE outbound_queue SET created_at = ? WHERE id = ?').run(authoredMs, id);

    const ws = await h.connectAuthed({ lastSeenInbound: 0 });
    const drained = await h.expectIncoming(ws);
    expect(drained.id).toBe(id);
    expect(drained.ts).toBe(new Date(authoredMs).toISOString());
    ws.close();
  });
});
