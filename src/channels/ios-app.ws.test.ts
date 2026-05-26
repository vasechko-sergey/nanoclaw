import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { WebSocketServer, WebSocket } from 'ws';
import { ReadReceiptStore } from './ios-read-receipts.js';
import { createIosWsHandler, type IosWsHandlerState } from './ios-app.js';

function makeState(): IosWsHandlerState {
  return {
    wsClients: new Map(),
    apnsTokens: new Map(),
    pendingMessages: new Map(),
    deliveredIds: new Map(),
    lastTimezone: new Map(),
  };
}

async function createTestServer() {
  const store = new ReadReceiptStore();
  const inbound: Array<{ pid: string; content: Record<string, unknown> }> = [];
  const state = makeState();
  const handler = createIosWsHandler({
    token: 'test-token',
    store,
    cfg: {
      onInbound: async (pid, _tid, msg) => {
        inbound.push({ pid, content: (msg as Record<string, unknown>).content as Record<string, unknown> });
      },
      onAction: () => {},
    },
    state,
    persist: { receipts: () => {}, tokens: () => {} },
    deliverQueued: () => {},
  });
  const server = createServer();
  const wss = new WebSocketServer({ server });
  wss.on('connection', handler);
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as AddressInfo).port;
  const close = () =>
    new Promise<void>((r) => {
      wss.close();
      server.close(() => r());
    });
  return { port, store, inbound, close };
}

async function connect(port: number): Promise<WebSocket> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  await new Promise<void>((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
  return ws;
}

async function auth(ws: WebSocket): Promise<Record<string, unknown>> {
  return new Promise((resolve) => {
    ws.once('message', (m) => resolve(JSON.parse(m.toString())));
    ws.send(JSON.stringify({ type: 'auth', token: 'test-token', platformId: 'ios:test-1' }));
  });
}

describe('ios-app WS protocol', () => {
  let ctx: Awaited<ReturnType<typeof createTestServer>>;

  beforeEach(async () => {
    ctx = await createTestServer();
  });
  afterEach(async () => {
    await ctx.close();
  });

  it('auth → auth_ok', async () => {
    const ws = await connect(ctx.port);
    const reply = await auth(ws);
    expect(reply.type).toBe('auth_ok');
    ws.close();
  });

  it('bad token → socket closed with code 4001', async () => {
    const ws = await connect(ctx.port);
    const closeCode = await new Promise<number>((resolve) => {
      ws.once('close', (code) => resolve(code));
      ws.send(JSON.stringify({ type: 'auth', token: 'wrong-token', platformId: 'ios:bad' }));
    });
    expect(closeCode).toBe(4001);
  });

  it('message with clientMessageId → message_ack with same id', async () => {
    const ws = await connect(ctx.port);
    await auth(ws);
    const ack = await new Promise<Record<string, unknown>>((resolve) => {
      ws.once('message', (m) => resolve(JSON.parse(m.toString())));
      ws.send(JSON.stringify({ type: 'message', text: 'hello', clientMessageId: 'cid-abc' }));
    });
    expect(ack.type).toBe('message_ack');
    expect(ack.clientMessageId).toBe('cid-abc');
    ws.close();
  });

  it('message_delivered → stored in ReadReceiptStore', async () => {
    const ws = await connect(ctx.port);
    await auth(ws);
    ws.send(JSON.stringify({ type: 'message_delivered', messageId: 'msg-1' }));
    await new Promise((r) => setTimeout(r, 50));
    const pending = ctx.store.getPending('ios:test-1');
    expect(pending).toHaveLength(1);
    expect(pending[0].messageId).toBe('msg-1');
    expect(pending[0].deliveredAt).toBeTruthy();
    ws.close();
  });

  it('message_read → readAt set on existing entry', async () => {
    const ws = await connect(ctx.port);
    await auth(ws);
    ws.send(JSON.stringify({ type: 'message_delivered', messageId: 'msg-2' }));
    ws.send(JSON.stringify({ type: 'message_read', messageId: 'msg-2' }));
    await new Promise((r) => setTimeout(r, 50));
    const pending = ctx.store.getPending('ios:test-1');
    const entry = pending.find((p) => p.messageId === 'msg-2');
    expect(entry?.readAt).toBeTruthy();
    ws.close();
  });
});
