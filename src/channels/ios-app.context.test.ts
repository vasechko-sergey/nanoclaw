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
  await new Promise<void>((resolve, reject) => {
    ws.once('message', () => resolve());
    ws.once('close', () => reject(new Error('closed before auth_ok')));
    ws.send(JSON.stringify({ type: 'auth', token: 'test-token', platformId: 'ios:ctx-test' }));
  });

  return { store, inbound, ws, close };
}

describe('ios-app context injection', () => {
  let ctx: Awaited<ReturnType<typeof setup>>;

  beforeEach(async () => {
    ctx = await setup();
  });
  afterEach(async () => {
    ctx.ws.terminate();
    await ctx.close();
  });

  it('context_response with pending receipts → inbound text contains [read receipts]', async () => {
    ctx.store.record('ios:ctx-test', 'msg-abc', 'delivered');
    ctx.ws.send(JSON.stringify({ type: 'context_response', context: { timezone: 'Asia/Tbilisi' } }));
    await new Promise((r) => setTimeout(r, 200));
    expect(ctx.inbound).toHaveLength(1);
    expect(ctx.inbound[0].text).toContain('[read receipts]');
    expect(ctx.inbound[0].text).toContain('msg-abc');
  });

  it('receipts are marked injected after context_response', async () => {
    ctx.store.record('ios:ctx-test', 'msg-xyz', 'delivered');
    ctx.ws.send(JSON.stringify({ type: 'context_response', context: {} }));
    await new Promise((r) => setTimeout(r, 200));
    expect(ctx.store.getPending('ios:ctx-test')).toHaveLength(0);
  });

  it('second context_response does not re-inject already injected receipts', async () => {
    ctx.store.record('ios:ctx-test', 'msg-dup', 'delivered');
    ctx.ws.send(JSON.stringify({ type: 'context_response', context: {} }));
    await new Promise((r) => setTimeout(r, 200));
    ctx.ws.send(JSON.stringify({ type: 'context_response', context: {} }));
    await new Promise((r) => setTimeout(r, 200));
    expect(ctx.inbound).toHaveLength(2);
    expect(ctx.inbound[1].text).not.toContain('msg-dup');
  });

  it('context_response without pending receipts → no [read receipts] block', async () => {
    ctx.ws.send(JSON.stringify({ type: 'context_response', context: {} }));
    await new Promise((r) => setTimeout(r, 200));
    expect(ctx.inbound[0].text).not.toContain('[read receipts]');
  });
});
