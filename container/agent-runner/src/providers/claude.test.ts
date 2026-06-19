import { test, expect } from 'bun:test';
import { extractToolResultText } from './claude.js';

test('extractToolResultText reads a string content block', () => {
  expect(extractToolResultText('TRC20 fee: 0.80 USDT')).toBe('TRC20 fee: 0.80 USDT');
});

test('extractToolResultText joins array text blocks', () => {
  const content = [
    { type: 'text', text: 'fee 0.80' },
    { type: 'text', text: ' net 0.1%' },
  ];
  expect(extractToolResultText(content)).toBe('fee 0.80 net 0.1%');
});

test('extractToolResultText returns empty for unknown shapes', () => {
  expect(extractToolResultText(undefined)).toBe('');
  expect(extractToolResultText(42 as unknown)).toBe('');
});
