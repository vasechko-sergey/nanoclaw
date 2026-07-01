import { describe, it, expect } from 'bun:test';

import { changeRatio, isReplacementEdit } from './edit-guard.js';

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
  it('exempts short messages (a tiny fix reads as a big % change)', () => {
    // The real "fix what I just said" case on toy strings.
    expect(isReplacementEdit('oops', 'corrected')).toBe(false);
  });

  it('allows a genuine correction of a long message', () => {
    const prev = 'Доход от продажи квартиры облагается 13% НДФЛ, если владел меньше 5 лет.';
    const next = 'Доход от продажи квартиры облагается 13% НДФЛ, если владел меньше 3 лет.';
    expect(isReplacementEdit(prev, next)).toBe(false);
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

  it('exempts an empty prior text (nothing to compare)', () => {
    expect(isReplacementEdit('', 'a brand new long-enough message body here')).toBe(false);
  });
});
