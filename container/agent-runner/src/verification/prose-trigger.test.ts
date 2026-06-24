import { test, expect } from 'bun:test';
import { shouldJudgeProse } from './prose-trigger.js';

test('fires only on level>=2 + tool output + prose', () => {
  expect(shouldJudgeProse(2, 'tool said x', 'Your balance is concentrated in Tbank.')).toBe(true);
});
test('skips when level < 2', () => {
  expect(shouldJudgeProse(1, 'tool said x', 'long enough prose here friend')).toBe(false);
  expect(shouldJudgeProse(0, 'tool said x', 'long enough prose here friend')).toBe(false);
});
test('skips when no tool output this turn', () => {
  expect(shouldJudgeProse(2, '', 'long enough prose here friend')).toBe(false);
});
test('skips trivial/number-only messages', () => {
  expect(shouldJudgeProse(2, 'tool', '$0.80')).toBe(false);
  expect(shouldJudgeProse(2, 'tool', 'ok')).toBe(false);
});
test('required cases from spec', () => {
  expect(shouldJudgeProse(2, 'tool out', 'this is a long enough sentence here')).toBe(true);
  expect(shouldJudgeProse(1, 'tool out', 'long sentence here now ok yes')).toBe(false);
});
