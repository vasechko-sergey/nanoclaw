// Test harness: boots a real ws.WebSocketServer + WsHandler on an ephemeral
// port with an in-memory transport DB. Used by ws-handler tests to exercise
// the full handshake / dispatch / retry / ping path against a live socket.
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { randomUUID } from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';
import { openTransportDb, type TransportDb } from '../transport-db.js';
import { OutboundQueue } from '../outbound-queue.js';
import { ReceiptStore } from '../receipt-store.js';
import { InboundDispatcher } from '../inbound-dispatch.js';
import { ContextBridge } from '../context-bridge.js';
import { WorkoutBridge } from '../workout-bridge.js';
import { WsHandler } from '../ws-handler.js';

export interface HarnessReceivedEvent {
  kind: string;
  [key: string]: unknown;
}

interface ClientState {
  buffer: any[];
  waiters: Array<(env: any) => void>;
  closeCode?: number;
  closeWaiters: Array<(code: number) => void>;
}

const CLIENT_STATE = new WeakMap<WebSocket, ClientState>();

function attachBuffer(ws: WebSocket): ClientState {
  const state: ClientState = { buffer: [], waiters: [], closeWaiters: [] };
  CLIENT_STATE.set(ws, state);
  ws.on('message', (raw) => {
    const env = JSON.parse(raw.toString());
    const waiter = state.waiters.shift();
    if (waiter) waiter(env);
    else state.buffer.push(env);
  });
  ws.on('close', (code) => {
    state.closeCode = code;
    while (state.closeWaiters.length) state.closeWaiters.shift()!(code);
  });
  return state;
}

function nextMessage(ws: WebSocket, timeoutMs: number): Promise<any> {
  const state = CLIENT_STATE.get(ws);
  if (!state) throw new Error('ws not attached to harness buffer');
  return new Promise<any>((resolve, reject) => {
    if (state.buffer.length) {
      resolve(state.buffer.shift());
      return;
    }
    const t = setTimeout(() => {
      const i = state.waiters.indexOf(resolveOnce);
      if (i >= 0) state.waiters.splice(i, 1);
      reject(new Error('expectIncoming timeout'));
    }, timeoutMs);
    const resolveOnce = (env: any) => {
      clearTimeout(t);
      resolve(env);
    };
    state.waiters.push(resolveOnce);
  });
}

export interface HarnessSystemWrite {
  session_id: string;
  text: string;
  tag: string;
}

export interface Harness {
  url: string;
  validToken: string;
  platformId: string;
  db: TransportDb;
  queue: OutboundQueue;
  bridge: ContextBridge;
  workoutBridge: WorkoutBridge;
  handler: WsHandler;
  agent: { received: HarnessReceivedEvent[]; systemWrites: HarnessSystemWrite[] };
  close(): Promise<void>;
  send(ws: WebSocket, envelope: unknown): void;
  expectIncoming(ws: WebSocket, timeoutMs?: number): Promise<any>;
  expectClose(ws: WebSocket, timeoutMs?: number): Promise<number>;
  connectRaw(): Promise<WebSocket>;
  connectAuthed(opts?: { lastSeenInbound?: number; capabilities?: string[] }): Promise<WebSocket>;
}

export async function startTestServer(): Promise<Harness> {
  const validToken = 'test-token';
  const platformId = 'ios-app:dev-1';
  const db = openTransportDb(':memory:');
  const queue = new OutboundQueue(db);
  const receipts = new ReceiptStore(db);
  const agent: { received: HarnessReceivedEvent[]; systemWrites: HarnessSystemWrite[] } = {
    received: [],
    systemWrites: [],
  };

  let bridge: ContextBridge;
  let handler: WsHandler;

  const workoutBridge = new WorkoutBridge({
    writeInboundSystemMessage: (input) => {
      agent.systemWrites.push(input);
      agent.received.push({ kind: 'system_message', ...input });
    },
    resolvePlatformForSession: () => platformId,
    sendEnvelopeToDevice: (pid, env) => handler.sendEnvelopeToDevice(pid, env),
  });

  const dispatcher = new InboundDispatcher({
    db,
    queue,
    receipts,
    resolveSessionForPlatform: (_pid, _agent) => 'sess-1',
    defaultAgentSlug: 'jarvis',
    workoutBridge,
    onUserMessage: (input) => {
      agent.received.push({ kind: 'user_message', ...input });
    },
    onContextResponse: (input) => {
      agent.received.push({ kind: 'context_response', ...input });
      bridge?.resolveDeviceResponse(input.envelope.payload.request_id);
    },
    onAction: (input) => {
      agent.received.push({ kind: 'action', ...input });
    },
    onNewConversation: (input) => {
      agent.received.push({ kind: 'new_conversation', ...input });
    },
    onFeedback: (input) => {
      agent.received.push({ kind: 'feedback', ...input });
    },
  });

  bridge = new ContextBridge({
    db,
    resolvePlatformForSession: () => platformId,
    sendEnvelopeToDevice: (pid, env) => handler.sendEnvelopeToDevice(pid, env),
    writeInboundContextResponse: (input) => {
      agent.received.push({ kind: 'context_response_synthetic', ...input });
    },
  });
  handler = new WsHandler({
    db,
    queue,
    dispatcher,
    contextBridge: bridge,
    validateToken: async (token) => (token === validToken ? platformId : null),
  });

  const server = http.createServer();
  const wss = new WebSocketServer({ server });
  handler.attach(wss);
  await new Promise<void>((resolve) => server.listen(0, resolve));
  const port = (server.address() as AddressInfo).port;
  const url = `ws://127.0.0.1:${port}`;

  const harness: Harness = {
    url,
    validToken,
    platformId,
    db,
    queue,
    bridge,
    workoutBridge,
    handler,
    agent,
    async close() {
      handler.shutdown();
      await new Promise<void>((r) => wss.close(() => r()));
      await new Promise<void>((r) => server.close(() => r()));
      db.raw.close();
    },
    send(ws, envelope) {
      ws.send(JSON.stringify(envelope));
    },
    expectIncoming(ws, timeoutMs = 2000) {
      return nextMessage(ws, timeoutMs);
    },
    expectClose(ws, timeoutMs = 2000) {
      const state = CLIENT_STATE.get(ws);
      if (!state) throw new Error('ws not attached to harness buffer');
      if (state.closeCode !== undefined) return Promise.resolve(state.closeCode);
      return new Promise<number>((resolve, reject) => {
        const t = setTimeout(() => {
          const i = state.closeWaiters.indexOf(resolveOnce);
          if (i >= 0) state.closeWaiters.splice(i, 1);
          reject(new Error('expectClose timeout'));
        }, timeoutMs);
        const resolveOnce = (code: number) => {
          clearTimeout(t);
          resolve(code);
        };
        state.closeWaiters.push(resolveOnce);
      });
    },
    async connectRaw() {
      const ws = new WebSocket(url);
      await new Promise<void>((resolve, reject) => {
        ws.once('open', () => resolve());
        ws.once('error', reject);
      });
      attachBuffer(ws);
      return ws;
    },
    async connectAuthed(opts = {}) {
      const ws = await harness.connectRaw();
      ws.send(
        JSON.stringify({
          v: 2,
          kind: 'control',
          type: 'auth',
          id: randomUUID(),
          seq: null,
          ts: new Date().toISOString(),
          payload: {
            token: validToken,
            last_seen_inbound_seq: opts.lastSeenInbound ?? 0,
            capabilities: opts.capabilities ?? [],
          },
        }),
      );
      const env = await nextMessage(ws, 2000);
      if (env.type !== 'auth_ok') {
        throw new Error(`expected auth_ok, got ${env.type}`);
      }
      return ws;
    },
  };
  return harness;
}
