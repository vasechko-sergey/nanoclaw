import { describe, it, expect } from 'vitest';
import { EnvelopeBase, InlineContext, ContextFieldEnum } from './v2';

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
