import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { randomUUID } from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';

import { openTransportDb, type TransportDb } from './transport-db.js';
import { OutboundQueue } from './outbound-queue.js';
import { ReceiptStore } from './receipt-store.js';
import { InboundDispatcher } from './inbound-dispatch.js';
import { ContextBridge } from './context-bridge.js';
import { WsHandler } from './ws-handler.js';

interface MiniHarness {
  url: string;
  db: TransportDb;
  handler: WsHandler;
  close(): Promise<void>;
}

async function startServer(opts: { commands?: Array<{ command: string; description: string }> }): Promise<MiniHarness> {
  const db = openTransportDb(':memory:');
  const queue = new OutboundQueue(db);
  const receipts = new ReceiptStore(db);
  const platformId = 'ios-app-v2:dev-1';

  let bridge: ContextBridge;
  let handler: WsHandler;

  const dispatcher = new InboundDispatcher({
    db,
    queue,
    receipts,
    resolveSessionForPlatform: () => 'sess-1',
    onUserMessage: () => {},
    onContextResponse: () => {},
    onAction: () => {},
    onNewConversation: () => {},
    onFeedback: () => {},
  });
  bridge = new ContextBridge({
    db,
    resolvePlatformForSession: () => platformId,
    sendEnvelopeToDevice: (pid, env) => handler.sendEnvelopeToDevice(pid, env),
    writeInboundContextResponse: () => {},
  });
  handler = new WsHandler({
    db,
    queue,
    dispatcher,
    contextBridge: bridge,
    validateToken: async (token) => (token === 'tok' ? platformId : null),
    commands: opts.commands,
  });

  const server = http.createServer();
  const wss = new WebSocketServer({ server });
  handler.attach(wss);
  await new Promise<void>((resolve) => server.listen(0, resolve));
  const port = (server.address() as AddressInfo).port;
  return {
    url: `ws://127.0.0.1:${port}`,
    db,
    handler,
    async close() {
      handler.shutdown();
      await new Promise<void>((r) => wss.close(() => r()));
      await new Promise<void>((r) => server.close(() => r()));
      db.raw.close();
    },
  };
}

async function authAndCaptureAuthOk(url: string): Promise<any> {
  const ws = new WebSocket(url);
  await new Promise<void>((resolve, reject) => {
    ws.once('open', () => resolve());
    ws.once('error', reject);
  });
  const incoming: any[] = [];
  const waiter = new Promise<any>((resolve) => {
    ws.on('message', (raw) => {
      const env = JSON.parse(raw.toString());
      incoming.push(env);
      if (env.type === 'auth_ok') resolve(env);
    });
  });
  ws.send(
    JSON.stringify({
      v: 2,
      kind: 'control',
      type: 'auth',
      id: randomUUID(),
      seq: null,
      ts: new Date().toISOString(),
      payload: { token: 'tok', last_seen_inbound_seq: 0, capabilities: [] },
    }),
  );
  const authOk = await waiter;
  ws.close();
  return authOk;
}

describe('WsHandler auth_ok commands', () => {
  let h: MiniHarness;
  afterEach(async () => {
    await h?.close();
  });

  it('omits commands field when none configured', async () => {
    h = await startServer({});
    const authOk = await authAndCaptureAuthOk(h.url);
    expect(authOk.type).toBe('auth_ok');
    expect(authOk.payload.commands).toBeUndefined();
  });

  it('includes commands list when configured', async () => {
    h = await startServer({
      commands: [
        { command: '/new', description: 'Start a new conversation' },
        { command: '/help', description: 'Show command list' },
      ],
    });
    const authOk = await authAndCaptureAuthOk(h.url);
    expect(authOk.type).toBe('auth_ok');
    expect(Array.isArray(authOk.payload.commands)).toBe(true);
    expect(authOk.payload.commands).toHaveLength(2);
    expect(authOk.payload.commands[0]).toEqual({
      command: '/new',
      description: 'Start a new conversation',
    });
  });

  it('omits commands field when configured as empty array', async () => {
    h = await startServer({ commands: [] });
    const authOk = await authAndCaptureAuthOk(h.url);
    expect(authOk.payload.commands).toBeUndefined();
  });
});
