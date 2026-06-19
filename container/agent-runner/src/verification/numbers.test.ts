import { test, expect } from 'bun:test';
import { extractDataNumbers, normalizeNumber } from './numbers.js';

test('normalizeNumber strips currency, %, thousands separators', () => {
  expect(normalizeNumber('$1.60')).toBe('1.6');
  expect(normalizeNumber('0.10%')).toBe('0.1');
  expect(normalizeNumber('8,728')).toBe('8728');
  expect(normalizeNumber('1 600')).toBe('1600');
});

test('extractDataNumbers picks currency/%/decimal/large, skips small bare ints', () => {
  const got = extractDataNumbers('Комиссия $1.60 и 0.1%, остаток 8,728, было 2 варианта и 3 подхода');
  expect(got.has('1.6')).toBe(true);
  expect(got.has('0.1')).toBe(true);
  expect(got.has('8728')).toBe(true);
  expect(got.has('2')).toBe(false);
  expect(got.has('3')).toBe(false);
});

test('extractDataNumbers returns empty for prose with no data', () => {
  expect(extractDataNumbers('привет, как дела').size).toBe(0);
});
