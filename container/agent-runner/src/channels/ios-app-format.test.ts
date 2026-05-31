import { describe, it, expect } from 'bun:test';
import { formatIosInbound } from './ios-app-format.js';

describe('formatIosInbound', () => {
  const text = 'remind me later';

  it('full context renders all parts', () => {
    const out = formatIosInbound(text, {
      location: { lat: 55.7619, lon: 37.5957, accuracy: 25 },
      timestamp: '2026-05-31T12:00:00.000Z',
      timezone: 'Europe/Moscow',
      locality: "Patriarch's Ponds",
    });
    expect(out).toContain('[iOS context — 2026-05-31T12:00:00Z Europe/Moscow, near "Patriarch\'s Ponds"');
    expect(out).toContain('loc=55.7619,37.5957 ±25m');
    expect(out.endsWith(text)).toBe(true);
  });

  it('no locality drops the near segment', () => {
    const out = formatIosInbound(text, {
      location: { lat: 1, lon: 2 },
      timestamp: '2026-05-31T12:00:00.000Z',
      timezone: 'UTC',
    });
    expect(out).not.toContain('near');
    expect(out).toContain('loc=1,2]');
  });

  it('no context returns text unchanged', () => {
    expect(formatIosInbound(text, undefined)).toBe(text);
  });
});
