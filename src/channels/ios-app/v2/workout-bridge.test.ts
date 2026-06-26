import { describe, it, expect, beforeEach } from 'vitest';
import { WorkoutBridge } from './workout-bridge.js';

describe('WorkoutBridge', () => {
  let writes: Array<{ session_id: string; text: string; tag: string; trigger: number }>;
  let sends: Array<{ pid: string; env: unknown }>;
  let bridge: WorkoutBridge;

  beforeEach(() => {
    writes = [];
    sends = [];
    bridge = new WorkoutBridge({
      writeInboundSystemMessage: (input) => writes.push(input),
      resolvePlatformForSession: () => 'ios-app:dev1',
      sendEnvelopeToDevice: (pid, env) => sends.push({ pid, env }),
    });
  });

  it('handlesInbound returns true for set_log', () => {
    expect(bridge.handlesInbound('set_log')).toBe(true);
  });

  it('handlesInbound returns false for unrelated types', () => {
    expect(bridge.handlesInbound('message')).toBe(false);
    expect(bridge.handlesInbound('workout_plan')).toBe(false); // outbound, not inbound
  });

  it('handlesOutbound returns true for workout_plan', () => {
    expect(bridge.handlesOutbound('workout_plan')).toBe(true);
  });

  it('writes set_log envelope as structured system inbound', () => {
    bridge.handleInbound('sess-payne', {
      type: 'set_log',
      payload: {
        workout_id: 'w1',
        exercise_slug: 'incline-db-press',
        set_idx: 0,
        reps: 10,
        weight: 22.5,
        reps_in_reserve: 3,
        ts: '2026-06-09T19:05:00Z',
      },
    } as any);
    expect(writes).toHaveLength(1);
    expect(writes[0].session_id).toBe('sess-payne');
    expect(writes[0].tag).toBe('workout');
    const body = JSON.parse(writes[0].text);
    expect(body.event).toBe('set_log');
    expect(body.payload.reps_in_reserve).toBe(3);
  });

  it('stamps set_log as accumulate context (trigger 0 — does not wake per-set)', () => {
    bridge.handleInbound('sess-payne', {
      type: 'set_log',
      payload: { workout_id: 'w1', set_idx: 0 },
    } as any);
    expect(writes[0].trigger).toBe(0);
  });

  it('stamps exercise_done as accumulate context (trigger 0)', () => {
    bridge.handleInbound('sess-payne', {
      type: 'exercise_done',
      payload: { workout_id: 'w1', exercise_slug: 'x' },
    } as any);
    expect(writes[0].trigger).toBe(0);
  });

  it('stamps workout_complete as a wake (trigger 1)', () => {
    bridge.handleInbound('sess-payne', {
      type: 'workout_complete',
      payload: { workout_id: 'w1', full_session_json: {} },
    } as any);
    expect(writes[0].trigger).toBe(1);
  });

  it('stamps image_request and swap as wakes (trigger 1)', () => {
    bridge.handleInbound('sess-payne', { type: 'image_request', payload: { slug: 'x' } } as any);
    bridge.handleInbound('sess-payne', { type: 'exercise_swap_request', payload: { workout_id: 'w1' } } as any);
    expect(writes[0].trigger).toBe(1);
    expect(writes[1].trigger).toBe(1);
  });

  it('ignores non-bridge envelope types on inbound', () => {
    bridge.handleInbound('sess-payne', {
      type: 'message',
      payload: { thread_id: 't', text: 'hi' },
    } as any);
    expect(writes).toHaveLength(0);
  });

  it('forwards workout_plan outbound to the device', () => {
    bridge.handleAgentRequest({
      session_id: 'sess-payne',
      content: {
        type: 'workout_plan',
        payload: { workout_id: 'w1', plan_json: {}, image_manifest: [] },
      },
    });
    expect(sends).toHaveLength(1);
    expect(sends[0].pid).toBe('ios-app:dev1');
    const env = sends[0].env as { type: string; payload: { workout_id: string } };
    expect(env.type).toBe('workout_plan');
    expect(env.payload.workout_id).toBe('w1');
  });

  it('ignores non-bridge content.type on outbound', () => {
    bridge.handleAgentRequest({
      session_id: 'sess-payne',
      content: { type: 'context_request', requestId: 'r1' },
    });
    expect(sends).toHaveLength(0);
  });

  it('skips outbound when no platform resolves', () => {
    const noDevBridge = new WorkoutBridge({
      writeInboundSystemMessage: () => {},
      resolvePlatformForSession: () => null,
      sendEnvelopeToDevice: (pid, env) => sends.push({ pid, env }),
    });
    noDevBridge.handleAgentRequest({
      session_id: 'sess-payne',
      content: { type: 'coach_message', payload: { text: 'go' } },
    });
    expect(sends).toHaveLength(0);
  });
});
