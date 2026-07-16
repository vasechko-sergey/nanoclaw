import { describe, expect, it } from 'vitest';

import { validateA2aKind } from './kinds.js';

describe('validateA2aKind', () => {
  it('passes a declared kind', () => {
    expect(validateA2aKind('set_log', '{"reps":8}', ['set_log', 'ack'])).toEqual({ ok: true, kind: 'set_log' });
  });

  it('rejects a kind the target does not declare', () => {
    expect(validateA2aKind('health_trend', '{}', ['finding', 'ack'])).toEqual({
      ok: false,
      code: 'unknown_kind',
      kind: 'health_trend',
    });
  });

  it('treats an omitted kind as text', () => {
    expect(validateA2aKind(null, 'привет', ['finding'])).toEqual({ ok: true, kind: 'text' });
    expect(validateA2aKind(undefined, 'привет', ['finding'])).toEqual({ ok: true, kind: 'text' });
    expect(validateA2aKind('', 'привет', ['finding'])).toEqual({ ok: true, kind: 'text' });
  });

  it('accepts text without it being declared', () => {
    expect(validateA2aKind('text', 'привет', [])).toEqual({ ok: true, kind: 'text' });
  });

  it('rejects a JSON-object body sent as text — the forgotten-attribute case', () => {
    expect(validateA2aKind(null, '{"exercise":"жим","weight_kg":80}', ['set_log'])).toEqual({
      ok: false,
      code: 'unmarked_json',
      kind: 'text',
    });
    expect(validateA2aKind('text', '  {"a":1}  ', ['set_log'])).toEqual({
      ok: false,
      code: 'unmarked_json',
      kind: 'text',
    });
  });

  it('does not treat JSON arrays or scalars as unmarked structure', () => {
    expect(validateA2aKind(null, '[1,2,3]', ['set_log'])).toEqual({ ok: true, kind: 'text' });
    expect(validateA2aKind(null, '42', ['set_log'])).toEqual({ ok: true, kind: 'text' });
    expect(validateA2aKind(null, 'null', ['set_log'])).toEqual({ ok: true, kind: 'text' });
    expect(validateA2aKind(null, '{не json}', ['set_log'])).toEqual({ ok: true, kind: 'text' });
  });

  it('ARMS the gate for an empty array — [] is not null', () => {
    // [] = descriptor present, declares no kinds = text-only, gate ARMED.
    // null = no descriptor = disarmed. Callers must never collapse one to the other.
    expect(validateA2aKind('set_log', '{}', [])).toEqual({ ok: false, code: 'unknown_kind', kind: 'set_log' });
  });

  it('DISARMS entirely when the target has no descriptor (legalKinds null)', () => {
    expect(validateA2aKind(null, '{"action":"set_log"}', null)).toEqual({ ok: true, kind: 'text' });
    expect(validateA2aKind('anything_at_all', '{}', null)).toEqual({ ok: true, kind: 'anything_at_all' });
  });
});
