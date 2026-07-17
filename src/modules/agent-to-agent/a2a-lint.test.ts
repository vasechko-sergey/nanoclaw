import { describe, expect, it } from 'vitest';

import { lintA2a, type LintInput } from './a2a-lint.js';

const base: LintInput = {
  descriptors: {
    greg: {
      role: 'Аналитик',
      a2a_in: {
        workout_summary: { desc: 'итог', from: ['payne'], fields: { date: 'string' } },
      },
      publishes: { desc: 'сводка', fields: { Готовность: 'N/100' } },
    },
    payne: {
      role: 'Тренер',
      a2a_in: {},
      publishes: { desc: 'трен', fields: { Программа: 'текст' } },
    },
  },
  sends: [{ from: 'payne', to: 'greg', kind: 'workout_summary', where: 'payne/skills/chat-log' }],
  edges: [{ from: 'payne', to: 'greg' }],
  fragmentRefs: [],
  rejected: [],
};

const codes = (i: LintInput) =>
  lintA2a(i)
    .map((f) => f.code)
    .sort();

describe('lintA2a', () => {
  it('is clean on a consistent set', () => {
    expect(lintA2a(base)).toEqual([]);
  });

  it('unknown_target: sends to an agent folder that does not exist at all', () => {
    expect(codes({ ...base, sends: [{ from: 'payne', to: 'ghost', kind: 'workout_summary', where: 'x' }] })).toContain(
      'unknown_target',
    );
  });

  it('unknown_kind: skill sends a kind the receiver does not declare', () => {
    expect(codes({ ...base, sends: [{ from: 'payne', to: 'greg', kind: 'health_trend', where: 'x' }] })).toContain(
      'unknown_kind',
    );
  });

  it('phantom_kind: declared kind nobody sends', () => {
    expect(codes({ ...base, sends: [] })).toContain('phantom_kind');
  });

  it('undeclared_sender: sender not in from[]', () => {
    expect(
      codes({
        ...base,
        sends: [{ from: 'jarvis', to: 'greg', kind: 'workout_summary', where: 'x' }],
        edges: [{ from: 'jarvis', to: 'greg' }],
        descriptors: { ...base.descriptors, jarvis: { role: 'Хаб' } },
      }),
    ).toContain('undeclared_sender');
  });

  it('missing_edge: from[] names an agent with no destination edge', () => {
    expect(codes({ ...base, edges: [] })).toContain('missing_edge');
  });

  it('unknown_sender: from[] names an agent folder that does not exist at all', () => {
    expect(
      codes({
        ...base,
        descriptors: {
          ...base.descriptors,
          greg: {
            ...base.descriptors.greg!,
            a2a_in: {
              workout_summary: { desc: 'итог', from: ['ghost'], fields: { date: 'string' } },
            },
          },
        },
        sends: [],
      }),
    ).toContain('unknown_sender');
  });

  it('dangling_reply: reply kind absent from the sender descriptor', () => {
    expect(
      codes({
        ...base,
        descriptors: {
          ...base.descriptors,
          greg: {
            ...base.descriptors.greg!,
            a2a_in: {
              workout_summary: { desc: 'итог', from: ['payne'], fields: {}, reply: 'nope' },
            },
          },
        },
      }),
    ).toContain('dangling_reply');
  });

  it('reply_not_sent: reply declared but no skill sends it back', () => {
    const found = lintA2a({
      ...base,
      descriptors: {
        ...base.descriptors,
        greg: {
          ...base.descriptors.greg!,
          a2a_in: { workout_summary: { desc: 'и', from: ['payne'], fields: {}, reply: 'ack' } },
        },
        payne: { ...base.descriptors.payne!, a2a_in: { ack: { desc: 'a', from: ['greg'], fields: {} } } },
      },
      edges: [
        { from: 'payne', to: 'greg' },
        { from: 'greg', to: 'payne' },
      ],
    });
    const f = found.find((x) => x.code === 'reply_not_sent');
    expect(f?.severity).toBe('warn');
  });

  it('no_publishes / no_role are warns, not errors', () => {
    const found = lintA2a({
      ...base,
      descriptors: { ...base.descriptors, jarvis: {} },
      sends: base.sends,
    });
    expect(found.find((f) => f.code === 'no_publishes')?.severity).toBe('warn');
    expect(found.find((f) => f.code === 'no_role')?.severity).toBe('warn');
  });

  it('optional_not_in_fields: optional names an unknown label', () => {
    expect(
      codes({
        ...base,
        descriptors: {
          ...base.descriptors,
          greg: { ...base.descriptors.greg!, publishes: { desc: 'd', fields: { A: 'x' }, optional: ['B'] } },
        },
      }),
    ).toContain('optional_not_in_fields');
  });

  it('unknown_fragment_ref: skill reads a fragment of a non-agent', () => {
    expect(codes({ ...base, fragmentRefs: [{ from: 'payne', target: 'ghost', where: 'x' }] })).toContain(
      'unknown_fragment_ref',
    );
  });

  it('a null descriptor produces no findings of its own — absent is not broken', () => {
    const found = lintA2a({ ...base, descriptors: { ...base.descriptors, scrooge: null } });
    // scrooge has no descriptor yet: name-only registry entry, gate disarmed.
    // That is a valid state, not drift — nothing about it may be reported.
    expect(found.filter((f) => f.msg.includes('scrooge'))).toEqual([]);
  });

  it('sending to a disarmed target is never an error — it fails open by design', () => {
    expect(
      codes({
        ...base,
        descriptors: { ...base.descriptors, scrooge: { role: 'Финансист' } },
        sends: [...base.sends, { from: 'payne', to: 'scrooge', kind: 'anything_at_all', where: 'x' }],
        edges: [...base.edges, { from: 'payne', to: 'scrooge' }],
      }),
    ).not.toContain('unknown_kind');
  });

  // --- Amendment: rejected fields must not read as a deliberate disarm. ---

  it('malformed_descriptor: a REJECTED a2a_in is an error, not a policy choice', () => {
    const found = lintA2a({ ...base, rejected: [{ folder: 'greg', field: 'a2a_in' }] });
    const f = found.find((x) => x.code === 'malformed_descriptor');
    expect(f?.severity).toBe('error');
    expect(f?.msg).toContain('РАЗОРУЖЁН');
  });

  it('malformed_descriptor: a rejected non-gate field is an error without the disarm warning', () => {
    const found = lintA2a({ ...base, rejected: [{ folder: 'greg', field: 'publishes' }] });
    const f = found.find((x) => x.code === 'malformed_descriptor');
    expect(f?.severity).toBe('error');
    expect(f?.msg).not.toContain('РАЗОРУЖЁН');
  });

  it('a DELIBERATE disarm stays silent — same observable state, opposite verdict', () => {
    // gordon declares nothing and rejects nothing: policy, not drift.
    const found = lintA2a({
      ...base,
      descriptors: {
        ...base.descriptors,
        gordon: { role: 'Нутрициолог', publishes: { desc: 'd', fields: { A: 'x' } } },
      },
    });
    expect(found.filter((f) => f.code === 'malformed_descriptor')).toEqual([]);
  });

  // --- Amendment: a whitelist typo must not silently pass through. ---

  it('unknown_contract_key: a kind contract carrying an unrecognized key is an error (e.g. "replay" typo for "reply")', () => {
    expect(
      codes({
        ...base,
        descriptors: {
          ...base.descriptors,
          greg: {
            ...base.descriptors.greg!,
            a2a_in: {
              workout_summary: {
                desc: 'итог',
                from: ['payne'],
                fields: { date: 'string' },
                replay: 'ack',
              } as any,
            },
          },
        },
      }),
    ).toContain('unknown_contract_key');
  });

  it('unknown_contract_key: a publishes contract carrying an unrecognized key is an error', () => {
    expect(
      codes({
        ...base,
        descriptors: {
          ...base.descriptors,
          greg: {
            ...base.descriptors.greg!,
            publishes: { desc: 'сводка', fields: { Готовность: 'N/100' }, extra: 'nope' } as any,
          },
        },
      }),
    ).toContain('unknown_contract_key');
  });
});
