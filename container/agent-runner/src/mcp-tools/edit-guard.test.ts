import { describe, it, expect } from 'bun:test';

import {
  changeRatio,
  classifyReplacement,
  isReplacementEdit,
  parseSqliteUtcMs,
  isStaleLastEdit,
  humanizeAge,
  EDIT_STALE_LAST_MS,
  MAX_CHANGE_RATIO,
} from './edit-guard.js';

describe('changeRatio', () => {
  it('is 0 for identical text', () => {
    expect(changeRatio('hello world', 'hello world')).toBe(0);
  });

  it('is 1 when nothing is shared', () => {
    expect(changeRatio('aaaa', 'bbbb')).toBe(1);
  });

  it('is small for a one-token correction in a long message', () => {
    const a = 'Всё обновлено 10 июня, кроме Bybit — там данные за прошлую неделю';
    const b = 'Всё обновлено 11 июня, кроме Bybit — там данные за прошлую неделю';
    expect(changeRatio(a, b)).toBeLessThan(0.1);
  });
});

describe('isReplacementEdit', () => {
  it('is the owner rule: at most 10% of a message changes in place', () => {
    expect(MAX_CHANGE_RATIO).toBe(0.1);
  });

  it('allows a slip fix (a number, a word)', () => {
    const prev = 'Доход от продажи квартиры облагается 13% НДФЛ, если владел меньше 5 лет.';
    const next = 'Доход от продажи квартиры облагается 13% НДФЛ, если владел меньше 3 лет.';
    expect(isReplacementEdit(prev, next)).toBe(false);
  });

  it('refuses a correction bigger than 10% — that goes as a separate message', () => {
    // Every number in a meal log changed (Gordon, 2026-07-11). The old 60% wall
    // let rewrites like this overwrite the bubble; the user never sees what was
    // wrong, only that the message silently changed.
    const prev = 'Записал. 562 ккал, 24г белка, 55г углей, 27г жира.';
    const next = 'Записал. 668 ккал, 53г белка, 19г углей, 42г жира.';
    expect(changeRatio(prev, next)).toBeGreaterThan(0.1);
    expect(changeRatio(prev, next)).toBeLessThan(0.6);
    expect(isReplacementEdit(prev, next)).toBe(true);
  });

  it('holds short messages to the same rule — a rewritten ack is a new message', () => {
    // Below 40 chars the old gate did not look at all, so a short "on it" bubble
    // could be overwritten wholesale.
    expect(isReplacementEdit('Щас дёрну Bybit, минуту...', 'Bybit: $952, остальное 🟡')).toBe(true);
  });

  it('boundary: exactly 10% passes, more does not', () => {
    const prev = 'a'.repeat(100);
    expect(isReplacementEdit(prev, 'b'.repeat(10) + 'a'.repeat(90))).toBe(false);
    expect(isReplacementEdit(prev, 'b'.repeat(11) + 'a'.repeat(89))).toBe(true);
  });

  it('blocks repurposing a bubble into a new-content list (the Scrooge bug)', () => {
    const prev = 'Контекст сброшен. Начинаем с чистого листа.';
    const next =
      'Балансы на 1 июля: SafePal earn 855.16$, SafePal wallet 66.65$, ' +
      'Telegram wallet 1712$, Bybit 340$, итого около 2973$ по кошелькам.';
    expect(isReplacementEdit(prev, next)).toBe(true);
  });

  it('blocks stuffing a long list onto the end of a short reply (large append)', () => {
    const prev = 'Всё обновлено 10 июня, кроме Bybit';
    const next =
      'Всё обновлено 10 июня, кроме Bybit. Балансы: SafePal earn 855.16$, ' +
      'SafePal wallet 66.65$, Telegram wallet 1712$, Bybit 340$, Binance 500$.';
    expect(isReplacementEdit(prev, next)).toBe(true);
  });

  it('refuses filling an empty message — that is new content', () => {
    expect(isReplacementEdit('', 'a brand new long-enough message body here')).toBe(true);
  });
});

describe('classifyReplacement', () => {
  it('returns the change ratio alongside the replacement verdict', () => {
    const prev = 'Контекст сброшен. Начинаем с чистого листа.';
    const next =
      'Балансы на 1 июля: SafePal earn 855.16$, SafePal wallet 66.65$, ' +
      'Telegram wallet 1712$, Bybit 340$, итого около 2973$ по кошелькам.';
    const c = classifyReplacement(prev, next);
    expect(c.isReplacement).toBe(true);
    expect(c.ratio).toBeGreaterThan(MAX_CHANGE_RATIO);
  });

  it('measures every edit — no length or empty-text exemption', () => {
    expect(classifyReplacement('oops', 'corrected').ratio).toBeGreaterThan(MAX_CHANGE_RATIO);
    expect(classifyReplacement('', 'new text')).toEqual({ ratio: 1, isReplacement: true });
  });

  it('agrees with isReplacementEdit', () => {
    const prev = 'a'.repeat(50);
    const next = 'b'.repeat(50);
    expect(isReplacementEdit(prev, next)).toBe(classifyReplacement(prev, next).isReplacement);
  });
});

describe('parseSqliteUtcMs', () => {
  it('parses a datetime(now) string as UTC', () => {
    // "2026-07-01 05:29:59" UTC == 1782883799000 ms.
    expect(parseSqliteUtcMs('2026-07-01 05:29:59')).toBe(Date.UTC(2026, 6, 1, 5, 29, 59));
  });

  it('is NaN for garbage', () => {
    expect(Number.isNaN(parseSqliteUtcMs('not a date'))).toBe(true);
  });
});

describe('isStaleLastEdit', () => {
  const base = Date.UTC(2026, 6, 1, 6, 0, 0);

  it('is false for a fresh message (a few minutes old)', () => {
    const ts = '2026-07-01 05:58:00'; // 2 min before base
    expect(isStaleLastEdit(ts, base)).toBe(false);
  });

  it('is true for a message older than the threshold', () => {
    const ts = '2026-07-01 04:30:00'; // 90 min before base
    expect(isStaleLastEdit(ts, base)).toBe(true);
  });

  it('is true for a days-old message (the Scrooge case)', () => {
    expect(isStaleLastEdit('2026-06-25 02:34:33', base)).toBe(true);
  });

  it('does not block on an unparseable timestamp', () => {
    expect(isStaleLastEdit('garbage', base)).toBe(false);
  });

  it('boundary: just under the threshold is fresh, just over is stale', () => {
    const justUnder = base - (EDIT_STALE_LAST_MS - 60000);
    const justOver = base - (EDIT_STALE_LAST_MS + 60000);
    const fmt = (ms: number) => new Date(ms).toISOString().replace('T', ' ').slice(0, 19);
    expect(isStaleLastEdit(fmt(justUnder), base)).toBe(false);
    expect(isStaleLastEdit(fmt(justOver), base)).toBe(true);
  });
});

describe('humanizeAge', () => {
  it('formats minutes, hours, days', () => {
    expect(humanizeAge(12 * 60000)).toBe('12 min');
    expect(humanizeAge(5 * 3600000)).toBe('5h');
    expect(humanizeAge(6 * 24 * 3600000)).toBe('6d');
  });
});
