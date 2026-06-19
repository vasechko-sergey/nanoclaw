import { test, expect } from 'bun:test';
import { gateOutboundText } from './poll-gate.js';

test('flags an ungrounded number inside a <message> block', () => {
  const text = '<message to="user">Комиссия TRC-20 ~$1.60</message>';
  const v = gateOutboundText(text, new Set(['8728']));
  expect(v.grounded).toBe(false);
  expect(v.ungrounded).toContain('1.6');
});

test('passes when the number is in the grounding set', () => {
  const text = '<message to="user">Комиссия $0.80 (из API)</message>';
  const v = gateOutboundText(text, new Set(['0.8']));
  expect(v.grounded).toBe(true);
});

test('scratchpad-only text is grounded', () => {
  expect(gateOutboundText('<internal>thinking 1.60</internal>', new Set()).grounded).toBe(true);
});
