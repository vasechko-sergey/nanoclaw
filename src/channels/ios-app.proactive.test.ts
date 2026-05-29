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

import http from 'node:http';

async function postJson(baseUrl: string, body: any, token: string): Promise<{ status: number }> {
  return new Promise((resolve, reject) => {
    const u = new URL(baseUrl);
    const req = http.request(
      {
        hostname: u.hostname,
        port: u.port,
        path: u.pathname,
        method: 'POST',
        headers: {
          authorization: `Bearer ${token}`,
          'content-type': 'application/json',
        },
      },
      (res) => {
        res.resume();
        res.on('end', () => resolve({ status: res.statusCode ?? 0 }));
      },
    );
    req.on('error', reject);
    req.write(JSON.stringify(body));
    req.end();
  });
}

describe('ios-app proactive triggers (HTTP path)', () => {
  async function setupHttp() {
    const { createIosHttpHandler } = await import('./ios-app.js');
    const inbound: Array<Record<string, unknown>> = [];
    const state = makeState();
    const httpHandler = createIosHttpHandler({
      token: 'test-token',
      cfg: {
        onInbound: async (_pid, _tid, msg) => {
          inbound.push(msg);
        },
      },
      state,
    });
    const server = createServer((req, res) => {
      httpHandler(req, res).catch(() => {
        res.statusCode = 500;
        res.end();
      });
    });
    await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
    const port = (server.address() as AddressInfo).port;
    return {
      inbound,
      baseUrl: `http://127.0.0.1:${port}`,
      close: () => new Promise<void>((r) => server.close(() => r())),
    };
  }

  it('POST /ios/proactive with valid bearer → 204 + onInbound system message', async () => {
    const { inbound, baseUrl, close } = await setupHttp();
    const res = await postJson(
      `${baseUrl}/ios/proactive`,
      {
        platformId: 'ios:http-test',
        trigger: 'geofence',
        payload: { lat: 8.6, lon: 115.1, city: 'Canggu' },
        ts: '2026-05-29T14:32:00+08:00',
        tz: 'Asia/Makassar',
      },
      'test-token',
    );
    expect(res.status).toBe(204);
    await new Promise((r) => setTimeout(r, 100));
    expect(inbound).toHaveLength(1);
    const text = (inbound[0].content as Record<string, unknown>).text as string;
    expect(text.startsWith('[proactive trigger=geofence')).toBe(true);
    await close();
  });

  it('POST /ios/proactive with bad bearer → 401', async () => {
    const { baseUrl, close } = await setupHttp();
    const res = await postJson(
      `${baseUrl}/ios/proactive`,
      { platformId: 'x', trigger: 'geofence', payload: {} },
      'wrong',
    );
    expect(res.status).toBe(401);
    await close();
  });
});
