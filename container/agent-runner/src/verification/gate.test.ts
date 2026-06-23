import { test, expect } from 'bun:test';
import { checkProvenance } from './gate.js';

test('grounded when every data-number appears in the grounding set', () => {
  const grounding = new Set(['1.6', '8728']);
  const r = checkProvenance('Комиссия $1.60, остаток 8,728', grounding);
  expect(r.grounded).toBe(true);
  expect(r.ungrounded).toEqual([]);
});

test('ungrounded number is flagged', () => {
  const grounding = new Set(['8728']);
  const r = checkProvenance('Комиссия TRC-20 ~$1.60', grounding);
  expect(r.grounded).toBe(false);
  expect(r.ungrounded).toContain('1.6');
});

test('no data-numbers → grounded (nothing to check)', () => {
  const r = checkProvenance('привет', new Set());
  expect(r.grounded).toBe(true);
});

test('grounded when message rounds a tool number to its displayed precision', () => {
  const grounding = new Set(['12009.34']);
  expect(checkProvenance('Траты $12009', grounding).grounded).toBe(true); // 0 dp
  expect(checkProvenance('Траты $12009.3', grounding).grounded).toBe(true); // 1 dp
  expect(checkProvenance('Траты $12009.34', grounding).grounded).toBe(true); // exact
});

test('still flags a genuinely different number, not a rounding', () => {
  const grounding = new Set(['12009.34']);
  const r = checkProvenance('Траты $12500', grounding);
  expect(r.grounded).toBe(false);
  expect(r.ungrounded).toContain('12500');
});
