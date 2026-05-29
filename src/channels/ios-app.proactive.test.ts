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
  const inbound: Array<Record<string, unknown>> = [];
  const handler = createIosWsHandler({
    token: 'test-token',
    store,
    cfg: {
      onInbound: async (_pid, _tid, msg) => {
        inbound.push(msg);
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
    ws.send(JSON.stringify({ type: 'auth', token: 'test-token', platformId: 'ios:proactive-test' }));
  });
  return { inbound, ws, close };
}

describe('ios-app proactive triggers (WS path)', () => {
  let ctx: Awaited<ReturnType<typeof setup>>;

  beforeEach(async () => {
    ctx = await setup();
  });
  afterEach(async () => {
    ctx.ws.terminate();
    await ctx.close();
  });

  it('geofence trigger → onInbound with [proactive trigger=geofence] prefix', async () => {
    ctx.ws.send(
      JSON.stringify({
        type: 'proactive',
        trigger: 'geofence',
        payload: { lat: 8.6478, lon: 115.1385, city: 'Canggu' },
        ts: '2026-05-29T14:32:00+08:00',
        tz: 'Asia/Makassar',
      }),
    );
    await new Promise((r) => setTimeout(r, 200));
    expect(ctx.inbound).toHaveLength(1);
    const content = (ctx.inbound[0] as Record<string, unknown>).content as Record<string, unknown>;
    const text = content.text as string;
    expect(text.startsWith('[proactive trigger=geofence')).toBe(true);
    expect(text).toContain('lat');
    expect(text).toContain('Canggu');
  });

  it('health_hr_spike trigger with empty payload still produces a valid system message', async () => {
    ctx.ws.send(
      JSON.stringify({
        type: 'proactive',
        trigger: 'health_hr_spike',
        payload: {},
        ts: '2026-05-29T14:32:00+08:00',
        tz: 'Asia/Makassar',
      }),
    );
    await new Promise((r) => setTimeout(r, 200));
    expect(ctx.inbound).toHaveLength(1);
    const content = (ctx.inbound[0] as Record<string, unknown>).content as Record<string, unknown>;
    const text = content.text as string;
    expect(text.startsWith('[proactive trigger=health_hr_spike')).toBe(true);
  });
});
