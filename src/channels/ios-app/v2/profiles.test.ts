import { describe, it, expect } from 'vitest';
import { parseProfile } from './profiles.js';

const greg = `---
updated: 2026-06-12
summary: Сон 6.2ч, пульс покоя 66, вариабельность ровная. Флагов нет.
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
});
