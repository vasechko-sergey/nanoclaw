import { test, expect } from 'bun:test';
import { parseFactualityGate } from './config.js';

test('parseFactualityGate defaults to off', () => {
  expect(parseFactualityGate(undefined)).toBe('off');
  expect(parseFactualityGate('nonsense')).toBe('off');
  expect(parseFactualityGate(null)).toBe('off');
});

test('parseFactualityGate accepts known modes', () => {
  expect(parseFactualityGate('deterministic')).toBe('deterministic');
  expect(parseFactualityGate('full')).toBe('full');
  expect(parseFactualityGate('off')).toBe('off');
});
