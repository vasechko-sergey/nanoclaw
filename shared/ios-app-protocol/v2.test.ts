import { describe, it, expect } from 'vitest';
import { EnvelopeBase, InlineContext, ContextFieldEnum, Envelopes, AnyEnvelope } from './v2';

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
