import { describe, it, expect } from 'vitest';
import { decideSummaryNotify, pluralRu, DEFAULT_SUMMARY_CFG } from './detector.js';

// Helper: epoch ms for a wall-clock time in Asia/Makassar (UTC+8, no DST).
// 08:46 WITA on 2026-06-30 == 00:46 UTC.
const witaToUtcMs = (h: number, m: number) => Date.UTC(2026, 5, 30, h - 8, m, 0); // month is 0-based; June = 5

const cfg = DEFAULT_SUMMARY_CFG; // window 08:40–09:15, quietMs 180000, tz Asia/Makassar

describe('decideSummaryNotify', () => {
  it('does not fire before any card today', () => {
    const r = decideSummaryNotify({ nowMs: witaToUtcMs(8, 46), cardMtimesMs: [], lastNotifiedDate: null, cfg });
    expect(r.fire).toBe(false);
  });

  it('does not fire while batch is still arriving (within quiet window)', () => {
    const r = decideSummaryNotify({
      nowMs: witaToUtcMs(8, 47),
      cardMtimesMs: [witaToUtcMs(8, 46)], // 1 min ago < 3 min
      lastNotifiedDate: null,
      cfg,
    });
    expect(r.fire).toBe(false);
  });

  it('fires once the batch has settled (no new card for >=3 min)', () => {
    const r = decideSummaryNotify({
      nowMs: witaToUtcMs(8, 51),
      cardMtimesMs: [witaToUtcMs(8, 46), witaToUtcMs(8, 47), witaToUtcMs(8, 48)],
      lastNotifiedDate: null,
      cfg,
    });
    expect(r.fire).toBe(true);
    expect(r.count).toBe(3);
  });

  it('fires at the deadline even if not settled', () => {
    const r = decideSummaryNotify({
      nowMs: witaToUtcMs(9, 15), // == windowEnd
      cardMtimesMs: [witaToUtcMs(9, 14)], // only 1 min old, but past deadline
      lastNotifiedDate: null,
      cfg,
    });
    expect(r.fire).toBe(true);
    expect(r.count).toBe(1);
  });

  it('does not fire twice the same day', () => {
    const r = decideSummaryNotify({
      nowMs: witaToUtcMs(8, 51),
      cardMtimesMs: [witaToUtcMs(8, 46)],
      lastNotifiedDate: '2026-06-30',
      cfg,
    });
    expect(r.fire).toBe(false);
  });

  it('ignores cards outside the morning window (e.g. midday republish)', () => {
    const r = decideSummaryNotify({
      nowMs: witaToUtcMs(12, 0),
      cardMtimesMs: [witaToUtcMs(11, 59)],
      lastNotifiedDate: null,
      cfg,
    });
    expect(r.fire).toBe(false);
  });

  it('pluralRu', () => {
    expect(pluralRu(1)).toBe('1 карточка');
    expect(pluralRu(3)).toBe('3 карточки');
    expect(pluralRu(5)).toBe('5 карточек');
    expect(pluralRu(11)).toBe('11 карточек');
    expect(pluralRu(21)).toBe('21 карточка');
  });
});
