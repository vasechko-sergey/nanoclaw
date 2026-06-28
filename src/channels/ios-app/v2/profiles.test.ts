import { describe, it, expect } from 'vitest';
import { parseProfile } from './profiles.js';

const greg = `---
updated: 2026-06-12
summary: Сон 6.2ч, пульс покоя 66, вариабельность ровная. Флагов нет.
action: Лёгкий день — нагрузку не грузи
metrics: [{"v":"68","l":"готовность","t":"warn"},{"v":"↓","l":"восст."},{"v":"6.2ч","l":"сон"}]
levels: {energy: 72, stress: 34, recovery: 81, readiness: 68}
recovery7d: [74, 77, 72, 80, 79, 85, 81]
---
- Пульс покоя: 66 (норма)
- Вариабельность: 55 (выше базы)
`;

describe('parseProfile', () => {
  it('extracts frontmatter fields, levels, and the body as detail', () => {
    const p = parseProfile('greg', greg);
    expect(p.updated).toBe('2026-06-12');
    expect(p.summary).toContain('Сон 6.2ч');
    expect(p.levels).toEqual({ energy: 72, stress: 34, recovery: 81, readiness: 68 });
    expect(p.recovery7d).toEqual([74, 77, 72, 80, 79, 85, 81]);
    expect(p.detail.trim().startsWith('- Пульс покоя')).toBe(true);
  });

  it('tolerates a fragment with no frontmatter', () => {
    const p = parseProfile('x', '# just a body\nhello');
    expect(p.summary).toBeNull();
    expect(p.detail).toContain('hello');
  });

  it('extracts action and metrics from frontmatter', () => {
    const p = parseProfile('greg', greg);
    expect(p.action).toBe('Лёгкий день — нагрузку не грузи');
    expect(p.metrics).toEqual([
      { v: '68', l: 'готовность', t: 'warn' },
      { v: '↓', l: 'восст.' },
      { v: '6.2ч', l: 'сон' },
    ]);
  });

  it('returns null metrics on malformed JSON, without throwing', () => {
    const text = `---\nsummary: x\nmetrics: [not json\n---\nbody`;
    const p = parseProfile('x', text);
    expect(p.metrics).toBeNull();
    expect(p.action).toBeNull();
  });

  it('clamps metrics to at most 3 and drops malformed entries', () => {
    const text = `---\nmetrics: [{"v":"1","l":"a"},{"v":"2","l":"b"},{"v":"3","l":"c"},{"v":"4","l":"d"},{"l":"no-v"}]\n---\nb`;
    const p = parseProfile('x', text);
    expect(p.metrics).toEqual([
      { v: '1', l: 'a' },
      { v: '2', l: 'b' },
      { v: '3', l: 'c' },
    ]);
  });
});
