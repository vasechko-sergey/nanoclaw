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
    processedClientMsgIds: new Map(),
  };
}

async function setup() {
  const store = new ReadReceiptStore();
  const inbound: Array<{ text: string }> = [];
  const handler = createIosWsHandler({
    token: 'test-token',
    store,
    cfg: {
      onInbound: async (_pid, _tid, msg) => {
        const content = (msg as Record<string, unknown>).content as Record<string, unknown>;
        inbound.push({ text: content.text as string });
      },
      onAction: () => {},
    },
    state: makeState(),
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
      for (const c of wss.clients) c.terminate();
      wss.close(() => server.close(() => r()));
    });

  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  await new Promise<void>((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
  const acks: string[] = [];
  ws.on('message', (data) => {
    const m = JSON.parse(data.toString());
    if (m.type === 'message_ack' && typeof m.clientMessageId === 'string') {
      acks.push(m.clientMessageId);
    }
  });
  await new Promise<void>((resolve, reject) => {
    ws.once('message', () => resolve());
    ws.once('close', () => reject(new Error('closed before auth_ok')));
    ws.send(JSON.stringify({ type: 'auth', token: 'test-token', platformId: 'ios:dup-test' }));
  });
  return { inbound, ws, close, acks };
}

describe('ios-app clientMessageId dedup', () => {
  let ctx: Awaited<ReturnType<typeof setup>>;

  beforeEach(async () => {
    ctx = await setup();
  });
  afterEach(async () => {
    ctx.ws.terminate();
    await ctx.close();
  });

  it('first message → onInbound called and ack emitted', async () => {
    ctx.ws.send(JSON.stringify({ type: 'message', text: 'hi', clientMessageId: 'cmsg-1' }));
    await new Promise((r) => setTimeout(r, 150));
    expect(ctx.inbound).toHaveLength(1);
    expect(ctx.acks).toContain('cmsg-1');
  });

  it('duplicate clientMessageId → onInbound not called again, ack still emitted', async () => {
    ctx.ws.send(JSON.stringify({ type: 'message', text: 'hi', clientMessageId: 'cmsg-2' }));
    await new Promise((r) => setTimeout(r, 100));
    ctx.ws.send(JSON.stringify({ type: 'message', text: 'hi', clientMessageId: 'cmsg-2' }));
    await new Promise((r) => setTimeout(r, 150));
    expect(ctx.inbound).toHaveLength(1);
    expect(ctx.acks.filter((a) => a === 'cmsg-2')).toHaveLength(2);
  });

  it('different clientMessageIds → both onInbound and both acks', async () => {
    ctx.ws.send(JSON.stringify({ type: 'message', text: 'a', clientMessageId: 'cmsg-3' }));
    await new Promise((r) => setTimeout(r, 100));
    ctx.ws.send(JSON.stringify({ type: 'message', text: 'b', clientMessageId: 'cmsg-4' }));
    await new Promise((r) => setTimeout(r, 150));
    expect(ctx.inbound).toHaveLength(2);
    expect(ctx.acks).toContain('cmsg-3');
    expect(ctx.acks).toContain('cmsg-4');
  });
});
