import { describe, it, expect } from 'vitest';
import { EnvelopeBase, InlineContext, ContextFieldEnum, Envelopes, AnyEnvelope } from './v2.js';

describe('EnvelopeBase', () => {
  const ok = {
    v: 2 as const, kind: 'data', type: 'message',
    id: '550e8400-e29b-41d4-a716-446655440000',
    seq: 1, ts: '2026-05-31T12:00:00.000Z',
  };

  it('accepts a minimal valid envelope', () => {
    expect(() => EnvelopeBase.parse(ok)).not.toThrow();
  });

  it('allows seq=null for stateless envelopes', () => {
    expect(() => EnvelopeBase.parse({ ...ok, seq: null })).not.toThrow();
  });

  it('rejects v != 2', () => {
    expect(() => EnvelopeBase.parse({ ...ok, v: 1 })).toThrow();
  });

  it('rejects negative seq', () => {
    expect(() => EnvelopeBase.parse({ ...ok, seq: -1 })).toThrow();
  });

  it('rejects non-uuid id', () => {
    expect(() => EnvelopeBase.parse({ ...ok, id: 'nope' })).toThrow();
  });
});

describe('InlineContext', () => {
  it('accepts a fully populated context', () => {
    expect(() => InlineContext.parse({
      location: { lat: 55.7, lon: 37.6, accuracy: 25 },
      timestamp: '2026-05-31T12:00:00.000Z',
      timezone: 'Europe/Moscow',
      locality: "Patriarch's Ponds",
    })).not.toThrow();
  });

  it('requires timestamp + timezone', () => {
    expect(() => InlineContext.parse({ timezone: 'UTC' })).toThrow();
    expect(() => InlineContext.parse({ timestamp: '2026-05-31T12:00:00.000Z' })).toThrow();
  });
});

describe('ContextFieldEnum', () => {
  it('lists exactly the v1 catalog', () => {
    const ALL = ['health','calendar','device','next_event','recent_locations','screen_state'];
    for (const f of ALL) expect(ContextFieldEnum.parse(f)).toBe(f);
    expect(() => ContextFieldEnum.parse('read_receipts')).toThrow();
    expect(() => ContextFieldEnum.parse('dialog_summary')).toThrow();
  });
});

const baseFor = (over: Record<string, unknown>) => ({
  v: 2 as const,
  kind: 'data',
  type: 'message',
  id: '550e8400-e29b-41d4-a716-446655440000',
  seq: 1,
  ts: '2026-05-31T12:00:00.000Z',
  ...over,
});

describe('Envelopes.Message', () => {
  it('accepts minimal message', () => {
    expect(() => Envelopes.Message.parse(baseFor({
      payload: { thread_id: 't1', text: 'hi' },
    }))).not.toThrow();
  });
  it('accepts message with inline context', () => {
    expect(() => Envelopes.Message.parse(baseFor({
      payload: {
        thread_id: 't1', text: 'hi',
        context: { timestamp: '2026-05-31T12:00:00.000Z', timezone: 'UTC' },
      },
    }))).not.toThrow();
  });
  it('rejects missing thread_id', () => {
    expect(() => Envelopes.Message.parse(baseFor({ payload: { text: 'hi' } }))).toThrow();
  });
});

describe('Envelopes.Auth', () => {
  it('accepts valid auth', () => {
    expect(() => Envelopes.Auth.parse(baseFor({
      kind: 'control', type: 'auth',
      payload: { token: 'abc', last_seen_inbound_seq: 0, capabilities: [] },
    }))).not.toThrow();
  });
});

describe('Envelopes.ContextRequest', () => {
  it('accepts request_id + non-empty fields', () => {
    expect(() => Envelopes.ContextRequest.parse(baseFor({
      kind: 'control', type: 'context_request',
      payload: {
        request_id: '550e8400-e29b-41d4-a716-446655440000',
        fields: ['device', 'next_event'],
      },
    }))).not.toThrow();
  });
  it('rejects empty fields', () => {
    expect(() => Envelopes.ContextRequest.parse(baseFor({
      kind: 'control', type: 'context_request',
      payload: {
        request_id: '550e8400-e29b-41d4-a716-446655440000',
        fields: [],
      },
    }))).toThrow();
  });
});

describe('AnyEnvelope discriminated union', () => {
  it('dispatches by type', () => {
    const env = baseFor({
      kind: 'control', type: 'auth',
      payload: { token: 'x', last_seen_inbound_seq: 0, capabilities: [] },
    });
    const parsed = AnyEnvelope.parse(env);
    expect(parsed.type).toBe('auth');
  });

  it('parses an update envelope (server→device edit)', () => {
    const env = AnyEnvelope.parse({
      v: 2,
      kind: 'data',
      type: 'update',
      id: '11111111-1111-4111-8111-111111111111',
      seq: 7,
      ts: '2026-06-23T12:00:00.000Z',
      payload: { id: 'msg-1750670000000-abc123', text: 'fixed' },
    });
    if (env.type !== 'update') throw new Error('expected update');
    expect(env.payload.id).toBe('msg-1750670000000-abc123');
    expect(env.payload.text).toBe('fixed');
  });
});

describe('Stateless envelopes (ack/ping/pong/status)', () => {
  it('Ack accepts seq=null', () => {
    expect(() => Envelopes.Ack.parse(baseFor({
      kind: 'ack', type: 'ack', seq: null,
      payload: { id: '550e8400-e29b-41d4-a716-446655440000', seq: 5 },
    }))).not.toThrow();
  });

  it('Ping accepts non-empty nonce', () => {
    expect(() => Envelopes.Ping.parse(baseFor({
      kind: 'control', type: 'ping', seq: null,
      payload: { nonce: 'abc' },
    }))).not.toThrow();
  });

  it('Pong mirrors ping', () => {
    expect(() => Envelopes.Pong.parse(baseFor({
      kind: 'control', type: 'pong', seq: null,
      payload: { nonce: 'abc' },
    }))).not.toThrow();
  });

  it('Status delivered/read accept batches of ids', () => {
    expect(() => Envelopes.StatusDelivered.parse(baseFor({
      kind: 'status', type: 'delivered', seq: null,
      payload: { ids: ['550e8400-e29b-41d4-a716-446655440000'] },
    }))).not.toThrow();
    expect(() => Envelopes.StatusRead.parse(baseFor({
      kind: 'status', type: 'read', seq: null,
      payload: { ids: ['550e8400-e29b-41d4-a716-446655440000'] },
    }))).not.toThrow();
  });
});

describe('agent_id field', () => {
  it('accepts a Message envelope without agent_id (backward compat)', () => {
    const parsed = Envelopes.Message.parse({
      v: 2, kind: 'data', type: 'message',
      id: '00000000-0000-4000-8000-000000000001',
      seq: 0, ts: '2026-06-08T12:00:00.000Z',
      payload: { thread_id: 't1', text: 'hi' },
    });
    expect(parsed.payload.agent_id).toBeUndefined();
  });

  it('accepts a Message envelope with agent_id', () => {
    const parsed = Envelopes.Message.parse({
      v: 2, kind: 'data', type: 'message',
      id: '00000000-0000-4000-8000-000000000002',
      seq: 1, ts: '2026-06-08T12:00:00.000Z',
      payload: { thread_id: 't1', text: 'hi', agent_id: 'payne' },
    });
    expect(parsed.payload.agent_id).toBe('payne');
  });

  it('accepts NewConversation with agent_id', () => {
    const parsed = Envelopes.NewConversation.parse({
      v: 2, kind: 'control', type: 'new_conversation',
      id: '00000000-0000-4000-8000-000000000003',
      seq: 2, ts: '2026-06-08T12:00:00.000Z',
      payload: { thread_id: 't1', agent_id: 'greg' },
    });
    expect(parsed.payload.agent_id).toBe('greg');
  });
});

describe('v2 voice fields', () => {
  it('InlineContext accepts respond_by_voice', () => {
    const r = InlineContext.safeParse({ timestamp: new Date().toISOString(), timezone: 'Asia/Makassar', respond_by_voice: true });
    expect(r.success).toBe(true);
  });
  it('attachment kind accepts audio', () => {
    const r = Envelopes.Message.safeParse({
      v: 2, kind: 'data', type: 'message',
      id: '00000000-0000-4000-8000-000000000000',
      seq: 0, ts: '2026-06-16T00:00:00.000Z',
      payload: { thread_id: 't', text: '', attachments: [{ id: '00000000-0000-0000-0000-000000000000', kind: 'audio', name: 'reply.ogg', mime_type: 'audio/ogg', byte_size: 1 }] },
    });
    expect(r.success).toBe(true);
  });
});

describe('workout envelopes', () => {
  const base = {
    v: 2 as const,
    id: '00000000-0000-4000-8000-000000000099',
    seq: 0,
    ts: '2026-06-09T18:00:00.000Z',
  };

  it('parses workout_start_request', () => {
    const e = Envelopes.WorkoutStartRequest.parse({
      ...base, kind: 'control', type: 'workout_start_request',
      payload: { date: '2026-06-09', agent_id: 'payne' },
    });
    expect(e.payload.date).toBe('2026-06-09');
  });

  it('parses workout_plan with image_manifest', () => {
    const e = Envelopes.WorkoutPlan.parse({
      ...base, kind: 'control', type: 'workout_plan',
      payload: {
        workout_id: '01J6Z8W3K2N5A7B9C1D3E5F7G9',
        plan_json: { day_name: 'Верх A', week: 1, week_label: 'лёгкая', exercises: [] },
        image_manifest: [{ slug: 'incline-db-press', sha256: 'abc' }],
        agent_id: 'payne',
      },
    });
    expect(e.payload.image_manifest).toHaveLength(1);
  });

  it('parses set_log', () => {
    const e = Envelopes.SetLog.parse({
      ...base, kind: 'data', type: 'set_log',
      payload: {
        workout_id: 'w1',
        exercise_slug: 'incline-db-press',
        set_idx: 0, reps: 10, weight: 22.5, reps_in_reserve: 3,
        ts: '2026-06-09T19:05:00.000Z',
        agent_id: 'payne',
      },
    });
    expect(e.payload.reps_in_reserve).toBe(3);
  });

  it('parses exercise_swap_request without proposed', () => {
    const e = Envelopes.ExerciseSwapRequest.parse({
      ...base, kind: 'control', type: 'exercise_swap_request',
      payload: { workout_id: 'w1', exercise_slug: 'incline-db-press', agent_id: 'payne' },
    });
    expect(e.payload.proposed).toBeUndefined();
  });

  it('parses workout_complete with full session', () => {
    const e = Envelopes.WorkoutComplete.parse({
      ...base, kind: 'data', type: 'workout_complete',
      payload: {
        workout_id: 'w1',
        full_session_json: { date: '2026-06-09', exercises: [] },
        agent_id: 'payne',
      },
    });
    expect(e.payload.workout_id).toBe('w1');
  });

  it('parses coach_message', () => {
    const e = Envelopes.CoachMessage.parse({
      ...base, kind: 'control', type: 'coach_message',
      payload: { text: 'сбавь до 20', workout_id: 'w1', agent_id: 'payne' },
    });
    expect(e.payload.text).toBe('сбавь до 20');
  });

  it('parses intro_request', () => {
    const e = Envelopes.IntroRequest.parse({
      ...base, kind: 'control', type: 'intro_request',
      payload: { agent_id: 'payne' },
    });
    expect(e.type).toBe('intro_request');
  });

  it('AnyEnvelope discriminated union accepts a workout type', () => {
    const parsed = AnyEnvelope.parse({
      ...base, kind: 'control', type: 'coach_message',
      payload: { text: 'go', agent_id: 'payne' },
    });
    expect(parsed.type).toBe('coach_message');
  });
});
