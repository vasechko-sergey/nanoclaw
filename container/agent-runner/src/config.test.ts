import { test, expect } from 'bun:test';
import { parseFactualityLevel } from './config.js';

test('parseFactualityLevel reads an integer level', () => {
  expect(parseFactualityLevel(0)).toBe(0);
  expect(parseFactualityLevel(1)).toBe(1);
  expect(parseFactualityLevel(2)).toBe(2);
  expect(parseFactualityLevel(3)).toBe(3);
});
test('parseFactualityLevel clamps out-of-range / junk to 0..3', () => {
  expect(parseFactualityLevel(9)).toBe(3);
  expect(parseFactualityLevel(-1)).toBe(0);
  expect(parseFactualityLevel('x')).toBe(0);
  expect(parseFactualityLevel(undefined)).toBe(0);
});
test('parseFactualityLevel falls back to the legacy string mode', () => {
  expect(parseFactualityLevel(undefined, 'deterministic')).toBe(1);
  expect(parseFactualityLevel(undefined, 'full')).toBe(2);
  expect(parseFactualityLevel(undefined, 'off')).toBe(0);
});
