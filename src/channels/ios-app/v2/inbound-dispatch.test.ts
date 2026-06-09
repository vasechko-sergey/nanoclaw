import { describe, it, expect, beforeEach, vi } from 'vitest';
import { openTransportDb, type TransportDb } from './transport-db.js';
import { OutboundQueue } from './outbound-queue.js';
import { ReceiptStore } from './receipt-store.js';
import { InboundDispatcher } from './inbound-dispatch.js';

const pid = 'ios-app:dev-1';
let db: TransportDb, q: OutboundQueue, receipts: ReceiptStore, d: InboundDispatcher;
let onInbound = vi.fn();
let onContextResponse = vi.fn();
let onAction = vi.fn();
let onNewConversation = vi.fn();
let onFeedback = vi.fn();

beforeEach(() => {
  db = openTransportDb(':memory:');
  db.upsertDevice(pid, {});
  q = new OutboundQueue(db);
  receipts = new ReceiptStore(db);
  onInbound = vi.fn();
  onContextResponse = vi.fn();
  onAction = vi.fn();
  onNewConversation = vi.fn();
  onFeedback = vi.fn();
  d = new InboundDispatcher({
    db,
    queue: q,
    receipts,
    resolveSessionForPlatform: (_pid, _agent) => 'sess-1',
    defaultAgentSlug: 'jarvis',
    routeToAgent: onInbound,
    onContextResponse,
    onAction,
    onNewConversation,
    onFeedback,
  });
});

const env = (over: Record<string, unknown> = {}): any => ({
  v: 2 as const,
  id: '11111111-1111-4111-8111-111111111111',
  ts: '2026-05-31T12:00:00.000Z',
  seq: 1,
  kind: 'data',
  type: 'message',
  payload: { thread_id: 'thr', text: 'hi' },
  ...over,
});

describe('InboundDispatcher', () => {
  it('routes message → onUserMessage and writes inbound_dedup', () => {
    const action = d.dispatch(pid, env());
    expect(action.kind).toBe('ack');
    expect(onInbound).toHaveBeenCalledTimes(1);
    expect(db.raw.prepare(`SELECT COUNT(*) AS n FROM inbound_dedup`).get()).toEqual({ n: 1 });
  });

  it('dedups by id and re-acks without re-dispatch', () => {
    const e = env();
    d.dispatch(pid, e);
    const second = d.dispatch(pid, e);
    expect(second.kind).toBe('ack');
    expect(onInbound).toHaveBeenCalledTimes(1);
  });

  it('advances last_seen_outbound_seq monotonically', () => {
    d.dispatch(pid, env({ seq: 5, id: '11111111-1111-4111-8111-111111111111' }));
    d.dispatch(pid, env({ seq: 3, id: '22222222-2222-4222-8222-222222222222' }));
    expect(db.getDevice(pid)!.last_seen_outbound_seq).toBe(5);
  });

  it('status:delivered records in ReceiptStore, never propagates', () => {
    d.dispatch(
      pid,
      env({
        kind: 'status',
        type: 'delivered',
        seq: null,
        payload: { ids: ['11111111-1111-4111-8111-111111111119'] },
      }),
    );
    const rec = db.raw.prepare(`SELECT state FROM receipts`).all();
    expect(rec).toEqual([{ state: 'delivered' }]);
    expect(onInbound).not.toHaveBeenCalled();
  });

  it('control:ping returns a pong action and does not persist', () => {
    const action = d.dispatch(
      pid,
      env({
        kind: 'control',
        type: 'ping',
        seq: null,
        payload: { nonce: 'n1' },
      }),
    );
    expect(action.kind).toBe('pong');
    if (action.kind === 'pong') expect(action.nonce).toBe('n1');
    expect(db.raw.prepare(`SELECT COUNT(*) AS n FROM inbound_dedup`).get()).toEqual({ n: 0 });
    expect(db.getDevice(pid)!.last_seen_outbound_seq).toBe(0);
  });

  it('passes inferred agent_id to resolver when present on envelope payload', () => {
    const calls: Array<{ pid: string; agent_id: string | undefined }> = [];
    const dispatcher = new InboundDispatcher({
      db,
      queue: q,
      receipts,
      resolveSessionForPlatform: (pid, agent_id) => {
        calls.push({ pid, agent_id });
        return 'sess-x';
      },
      defaultAgentSlug: 'jarvis',
      routeToAgent: onInbound,
      onContextResponse,
      onAction,
      onNewConversation,
      onFeedback,
    });
    dispatcher.dispatch(pid, env({ payload: { thread_id: 'thr', text: 'go', agent_id: 'payne' } }));
    expect(calls).toEqual([{ pid, agent_id: 'payne' }]);
  });

  it('falls back to defaultAgentSlug when envelope omits agent_id', () => {
    const calls: Array<{ pid: string; agent_id: string | undefined }> = [];
    const dispatcher = new InboundDispatcher({
      db,
      queue: q,
      receipts,
      resolveSessionForPlatform: (pid, agent_id) => {
        calls.push({ pid, agent_id });
        return 'sess-x';
      },
      defaultAgentSlug: 'greg',
      routeToAgent: onInbound,
      onContextResponse,
      onAction,
      onNewConversation,
      onFeedback,
    });
    dispatcher.dispatch(pid, env({ payload: { thread_id: 'thr', text: 'no agent' } }));
    expect(calls).toEqual([{ pid, agent_id: 'greg' }]);
  });

  it('routes set_log envelope through workout bridge instead of onUserMessage', () => {
    const bridgeCalls: Array<{ sid: string; type: string }> = [];

    const dispatcher = new InboundDispatcher({
      db,
      queue: q,
      receipts,
      resolveSessionForPlatform: (_pid, _agent) => 'sess-1',
      defaultAgentSlug: 'jarvis',
      routeToAgent: onInbound,
      onContextResponse,
      onAction,
      onNewConversation,
      onFeedback,
      workoutBridge: {
        handlesInbound: (t: string) => t === 'set_log',
        handleInbound: (sid: string, e: any) => bridgeCalls.push({ sid, type: e.type }),
      } as any,
    });

    dispatcher.dispatch(
      pid,
      env({
        type: 'set_log',
        kind: 'data',
        payload: {
          workout_id: 'w1',
          exercise_slug: 'incline-db-press',
          set_idx: 0,
          reps: 10,
          weight: 22.5,
          reps_in_reserve: 3,
          ts: '2026-06-09T19:05:00.000Z',
          agent_id: 'payne',
        },
      }),
    );

    expect(onInbound).not.toHaveBeenCalled();
    expect(bridgeCalls).toEqual([{ sid: 'sess-1', type: 'set_log' }]);
  });

  it('context_response calls onContextResponse', () => {
    d.dispatch(
      pid,
      env({
        kind: 'control',
        type: 'context_response',
        seq: 7,
        id: '99999999-9999-4999-8999-999999999999',
        payload: {
          request_id: '55555555-5555-4555-8555-555555555556',
          data: { device: { battery: 0.5 } },
        },
      }),
    );
    expect(onContextResponse).toHaveBeenCalledWith(
      expect.objectContaining({
        envelope: expect.objectContaining({
          payload: expect.objectContaining({
            request_id: '55555555-5555-4555-8555-555555555556',
          }),
        }),
      }),
    );
  });
});
