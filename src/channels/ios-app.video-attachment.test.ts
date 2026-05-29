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
    ws.send(JSON.stringify({ type: 'auth', token: 'test-token', platformId: 'ios:video-test' }));
  });
  return { inbound, ws, close };
}

describe('ios-app video attachment forwarding', () => {
  let ctx: Awaited<ReturnType<typeof setup>>;

  beforeEach(async () => {
    ctx = await setup();
  });
  afterEach(async () => {
    ctx.ws.terminate();
    await ctx.close();
  });

  it('attachment with duration → onInbound payload preserves duration', async () => {
    ctx.ws.send(
      JSON.stringify({
        type: 'message',
        text: 'video please',
        attachments: [
          {
            name: 'clip.mp4',
            mimeType: 'video/mp4',
            data: Buffer.from('fake-bytes').toString('base64'),
            size: 10,
            duration: 18,
          },
        ],
      }),
    );
    await new Promise((r) => setTimeout(r, 200));
    expect(ctx.inbound).toHaveLength(1);
    const content = (ctx.inbound[0] as Record<string, unknown>).content as Record<string, unknown>;
    const atts = content.attachments as Array<Record<string, unknown>>;
    expect(atts).toHaveLength(1);
    expect(atts[0].name).toBe('clip.mp4');
    expect(atts[0].duration).toBe(18);
  });

  it('attachment without duration → no duration key forwarded', async () => {
    ctx.ws.send(
      JSON.stringify({
        type: 'message',
        text: 'pic',
        attachments: [
          {
            name: 'photo.jpg',
            mimeType: 'image/jpeg',
            data: Buffer.from('fake').toString('base64'),
            size: 4,
          },
        ],
      }),
    );
    await new Promise((r) => setTimeout(r, 200));
    expect(ctx.inbound).toHaveLength(1);
    const content = (ctx.inbound[0] as Record<string, unknown>).content as Record<string, unknown>;
    const atts = content.attachments as Array<Record<string, unknown>>;
    expect(atts).toHaveLength(1);
    expect(atts[0].duration).toBeUndefined();
  });
});
