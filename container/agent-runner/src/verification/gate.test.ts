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

test('grounds a comma list when every part is individually grounded', () => {
  // "105,212,309" fuses to a phantom "105212309" the agent never claimed; the
  // gate must read it as a list of three grounded numbers, not one ungrounded number.
  const grounding = new Set(['105', '212', '309']);
  const r = checkProvenance('встречи 105,212,309', grounding);
  expect(r.grounded).toBe(true);
  expect(r.ungrounded).toEqual([]);
});

test('grounds a space-separated 3-digit list by its parts', () => {
  const grounding = new Set(['100', '200', '300']);
  const r = checkProvenance('точки 100 200 300', grounding);
  expect(r.grounded).toBe(true);
});

test('flags the real list parts, never the fused phantom, when one part is missing', () => {
  const grounding = new Set(['105', '309']); // 212 missing
  const r = checkProvenance('встречи 105,212,309', grounding);
  expect(r.grounded).toBe(false);
  expect(r.ungrounded).toContain('212');
  expect(r.ungrounded).not.toContain('105212309'); // no alien phantom
  expect(r.ungrounded).not.toContain('105'); // grounded part not reported
  expect(r.ungrounded).not.toContain('309');
});

test('a real grounded thousands-number passes by its fused value', () => {
  const grounding = new Set(['1234567']);
  expect(checkProvenance('выручка 1,234,567', grounding).grounded).toBe(true);
});

test('a fabricated thousands-number cannot false-pass via parts (sub-100 leading group never grounds)', () => {
  // Even with 234 and 567 in the grounding set, the leading "1" (<100) is never
  // admitted, so 1,234,567 can never decompose into an all-grounded list.
  const grounding = new Set(['234', '567']);
  const r = checkProvenance('выручка 1,234,567', grounding);
  expect(r.grounded).toBe(false);
});
