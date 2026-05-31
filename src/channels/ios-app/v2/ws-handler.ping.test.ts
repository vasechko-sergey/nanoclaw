import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { randomUUID } from 'node:crypto';
import { startTestServer, type Harness } from './testing/harness.js';

function pingEnv(nonce: string) {
  return {
    v: 2,
    kind: 'control',
    type: 'ping',
    id: randomUUID(),
    seq: null,
    ts: new Date().toISOString(),
    payload: { nonce },
  };
}

describe('WsHandler ping isolation', () => {
  let h: Harness;
  beforeEach(async () => {
    h = await startTestServer();
  });
  afterEach(async () => {
    await h.close();
  });

  it('replies to control:ping with control:pong { same nonce }', async () => {
    const ws = await h.connectAuthed();
    h.send(ws, pingEnv('nonce-abc'));
    const pong = await h.expectIncoming(ws);
    expect(pong.kind).toBe('control');
    expect(pong.type).toBe('pong');
    expect(pong.seq).toBeNull();
    expect(pong.payload.nonce).toBe('nonce-abc');
    ws.close();
  });

  it('does NOT write inbound_dedup for ping', async () => {
    const ws = await h.connectAuthed();
    const before = h.db.raw.prepare('SELECT COUNT(*) AS n FROM inbound_dedup').get() as { n: number };
    h.send(ws, pingEnv('nonce-1'));
    await h.expectIncoming(ws);
    const after = h.db.raw.prepare('SELECT COUNT(*) AS n FROM inbound_dedup').get() as { n: number };
    expect(after.n).toBe(before.n);
    ws.close();
  });

  it('does NOT enqueue an outbound_queue row for the pong reply', async () => {
    const ws = await h.connectAuthed();
    h.send(ws, pingEnv('nonce-2'));
    await h.expectIncoming(ws);
    // pong is a transient control frame — seq is null, so it bypasses the queue.
    const rows = h.queue.list(h.platformId);
    expect(rows).toHaveLength(0);
    ws.close();
  });

  it('does NOT advance last_seen_outbound_seq', async () => {
    const ws = await h.connectAuthed();
    const before = h.db.getDevice(h.platformId)!.last_seen_outbound_seq;
    h.send(ws, pingEnv('nonce-3'));
    await h.expectIncoming(ws);
    const after = h.db.getDevice(h.platformId)!.last_seen_outbound_seq;
    expect(after).toBe(before);
    expect(after).toBe(0);
    ws.close();
  });

  it('does NOT dispatch to the agent', async () => {
    const ws = await h.connectAuthed();
    h.send(ws, pingEnv('nonce-4'));
    await h.expectIncoming(ws);
    expect(h.agent.received).toHaveLength(0);
    ws.close();
  });
});
