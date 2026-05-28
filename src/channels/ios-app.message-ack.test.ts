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
  const handler = createIosWsHandler({
    token: 'test-token',
    store,
    cfg: { onInbound: async () => {}, onAction: () => {} },
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
  const messages: Record<string, unknown>[] = [];
  ws.on('message', (data) => {
    messages.push(JSON.parse(data.toString()));
  });
  await new Promise<void>((resolve) => {
    const w = (m: { type: string }) => {
      if (m.type === 'auth_ok') resolve();
    };
    ws.on('message', (data) => w(JSON.parse(data.toString())));
    ws.send(JSON.stringify({ type: 'auth', token: 'test-token', platformId: 'ios:ack-test' }));
  });
  return { messages, ws, close };
}

describe('ios-app message_ack contract', () => {
  let ctx: Awaited<ReturnType<typeof setup>>;

  beforeEach(async () => {
    ctx = await setup();
  });
  afterEach(async () => {
    ctx.ws.terminate();
    await ctx.close();
  });

  it('every message with clientMessageId gets a matching ack', async () => {
    ctx.ws.send(JSON.stringify({ type: 'message', text: 'hi', clientMessageId: 'unique-1' }));
    await new Promise((r) => setTimeout(r, 200));
    const acks = ctx.messages.filter((m) => m.type === 'message_ack');
    expect(acks).toHaveLength(1);
    expect((acks[0] as { clientMessageId: string }).clientMessageId).toBe('unique-1');
  });

  it('message without clientMessageId gets no ack (backward compat)', async () => {
    ctx.ws.send(JSON.stringify({ type: 'message', text: 'hi' }));
    await new Promise((r) => setTimeout(r, 200));
    const acks = ctx.messages.filter((m) => m.type === 'message_ack');
    expect(acks).toHaveLength(0);
  });
});
