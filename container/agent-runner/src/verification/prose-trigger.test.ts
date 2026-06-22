import { test, expect } from 'bun:test';
import { shouldJudgeProse } from './prose-trigger.js';

test('fires only on full + tool output + prose', () => {
  expect(shouldJudgeProse('full', 'tool said x', 'Your balance is concentrated in Tbank.')).toBe(true);
});
test('skips when not full mode', () => {
  expect(shouldJudgeProse('deterministic', 'tool said x', 'long enough prose here friend')).toBe(false);
  expect(shouldJudgeProse('off', 'tool said x', 'long enough prose here friend')).toBe(false);
});
test('skips when no tool output this turn', () => {
  expect(shouldJudgeProse('full', '', 'long enough prose here friend')).toBe(false);
});
test('skips trivial/number-only messages', () => {
  expect(shouldJudgeProse('full', 'tool', '$0.80')).toBe(false);
  expect(shouldJudgeProse('full', 'tool', 'ok')).toBe(false);
});
