#!/usr/bin/env tsx
// E2E harness for iOS Simulator tests. Spawns a WebSocket server that plays
// one of several predefined scenarios (happy | offline_queue | context | reconnect | restart).
//
// Env:
//   E2E_PORT      — port to listen on (default 8801)
//   E2E_SCENARIO  — happy | offline_queue | context | reconnect | restart (default happy)
//   E2E_TOKEN     — accepted auth token (default 'test-token')
import { WebSocketServer, WebSocket } from 'ws';
import { randomUUID } from 'node:crypto';
import { AnyEnvelope } from '../shared/ios-app-protocol/index.js';

const port = Number(process.env.E2E_PORT ?? 8801);
const scenario = (process.env.E2E_SCENARIO ?? 'happy') as Scenario;
const validToken = process.env.E2E_TOKEN ?? 'test-token';

type Scenario = 'happy' | 'offline_queue' | 'context' | 'reconnect' | 'restart';

const wss = new WebSocketServer({ port });

interface ConnState {
  ws: WebSocket;
  platformId: string;
  authed: boolean;
  outboundSeq: number;        // adapter→app seq counter
}

const connections = new Set<ConnState>();
const log = (...args: unknown[]) => console.error('[e2e-harness]', ...args);

wss.on('connection', ws => {
  const state: ConnState = { ws, platformId: '', authed: false, outboundSeq: 0 };
  connections.add(state);
  log('connection opened, scenario=', scenario);
  ws.on('message', async raw => {
    let env: AnyEnvelope;
    try {
      env = AnyEnvelope.parse(JSON.parse(raw.toString()));
    } catch {
      log('protocol violation, closing');
      ws.close(4002, 'protocol_violation');
      return;
    }
    await handleFrame(state, env);
  });
  ws.on('close', () => {
    connections.delete(state);
    log('connection closed');
  });
});

async function handleFrame(state: ConnState, env: AnyEnvelope) {
  if (!state.authed) {
    if (env.type !== 'auth') {
      state.ws.close(4003, 'expected_auth');
      return;
    }
    if (env.payload.token !== validToken) {
      state.ws.close(4003, 'invalid_token');
      return;
    }
    state.authed = true;
    state.platformId = 'ios-app-v2:default';
    sendEnvelope(state, {
      v: 2, kind: 'control', type: 'auth_ok',
      id: randomUUID(), seq: null,
      ts: new Date().toISOString(),
      payload: { last_seen_outbound_seq: env.payload.last_seen_inbound_seq, server_time: new Date().toISOString() },
    });
    await runScenario(state);
    return;
  }

  switch (env.type) {
    case 'ping':
      sendEnvelope(state, {
        v: 2, kind: 'control', type: 'pong',
        id: randomUUID(), seq: null,
        ts: new Date().toISOString(),
        payload: { nonce: env.payload.nonce },
      });
      return;
    case 'message':
      // Always ack inbound user messages.
      sendEnvelope(state, {
        v: 2, kind: 'ack', type: 'ack',
        id: randomUUID(), seq: null,
        ts: new Date().toISOString(),
        payload: { id: env.id, seq: env.seq ?? 0 },
      });
      // Echo a reply for scenario 'happy'.
      if (scenario === 'happy') {
        await sleep(50);
        pushInbound(state, env.payload.thread_id, `echo: ${env.payload.text}`);
      }
      return;
    case 'context_response':
      log('context_response received', env.payload.request_id);
      sendEnvelope(state, {
        v: 2, kind: 'ack', type: 'ack',
        id: randomUUID(), seq: null,
        ts: new Date().toISOString(),
        payload: { id: env.id, seq: env.seq ?? 0 },
      });
      return;
    case 'ack':
    case 'delivered':
    case 'read':
    case 'feedback':
    case 'action_response':
    case 'new_conversation':
      return;
  }
}

async function runScenario(state: ConnState) {
  switch (scenario) {
    case 'happy':
      // Wait for the client to send something; reply when it arrives.
      return;
    case 'offline_queue':
      // App expected to enqueue messages while disconnected; nothing for harness to do.
      return;
    case 'context':
      // Send a context_request after auth.
      await sleep(200);
      sendEnvelope(state, {
        v: 2, kind: 'control', type: 'context_request',
        id: randomUUID(), seq: nextOutboundSeq(state),
        ts: new Date().toISOString(),
        payload: {
          request_id: randomUUID(),
          fields: ['device'],
          params: {},
        },
      });
      return;
    case 'reconnect':
      // Allow client to connect; close abruptly after 500ms. Client should reconnect.
      await sleep(500);
      state.ws.close(1011, 'simulated_drop');
      return;
    case 'restart':
      // Push a message every 500ms for the client to render. App killed/relaunched mid-run
      // — the queued message lands after relaunch.
      for (let i = 0; i < 3; i++) {
        await sleep(500);
        pushInbound(state, 'thr-1', `restart-msg-${i}`);
      }
      return;
  }
}

function sendEnvelope(state: ConnState, env: unknown) {
  if (state.ws.readyState !== WebSocket.OPEN) return;
  state.ws.send(JSON.stringify(env));
}

function nextOutboundSeq(state: ConnState): number {
  state.outboundSeq += 1;
  return state.outboundSeq;
}

function pushInbound(state: ConnState, threadId: string, text: string) {
  sendEnvelope(state, {
    v: 2, kind: 'data', type: 'message',
    id: randomUUID(), seq: nextOutboundSeq(state),
    ts: new Date().toISOString(),
    payload: { thread_id: threadId, text },
  });
}

const sleep = (ms: number) => new Promise<void>(r => setTimeout(r, ms));

log(`listening on ws://127.0.0.1:${port} scenario=${scenario} token=${validToken}`);
