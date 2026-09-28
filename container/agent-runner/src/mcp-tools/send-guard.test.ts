import { describe, it, expect } from 'bun:test';

import { MAX_ACK_CHARS, ackOnlyRefusal } from './send-guard.js';

describe('ackOnlyRefusal (send_message to a person while fact-checking is on)', () => {
  it('lets a short acknowledgement through', () => {
    const ack = 'Принял, солдат. Копаю научпоп и исследования по отдыху между упражнениями — через минуту доложу.';
    expect(ackOnlyRefusal(ack, 3)).toBeNull();
  });

  it('ignores small bare counts — the gate does not check them either', () => {
    expect(ackOnlyRefusal('Нашёл 3 варианта, сравниваю отзывы', 3)).toBeNull();
  });

  it('refuses figures even in a short text — they would skip the number check', () => {
    // Gordon, 2026-07-12: a corrected meal log sent this way, never checked.
    const r = ackOnlyRefusal('Исправил: вафля вместо булочки. Итого: 597 ккал, 36.8г белка, 36г жира.', 3);
    expect(r).not.toBeNull();
    expect(r!).toContain('597');
    expect(r!).toContain('36.8');
    expect(r!).toContain('<message>');
  });

  it('refuses content-sized text without figures — prose would skip the claim checks', () => {
    // Jarvis, 2026-09-27: a bounced answer re-sent in full this way (1969 chars).
    const answer =
      'BPJS оставьте как формальность для продления визы — прямого биллинга с нормальными больницами нет, ' +
      'для реального лечения не годится. Рабочие варианты — международные полисы с эвакуацией и прямым ' +
      'биллингом в частных клиниках Бали, их и сравниваем по отзывам о выплатах.';
    expect(answer.length).toBeGreaterThan(MAX_ACK_CHARS);
    const r = ackOnlyRefusal(answer, 3);
    expect(r).not.toBeNull();
    expect(r!).toContain(`${answer.length} characters`);
  });

  it('boundary: MAX_ACK_CHARS passes, one more does not', () => {
    expect(ackOnlyRefusal('а'.repeat(MAX_ACK_CHARS), 3)).toBeNull();
    expect(ackOnlyRefusal('а'.repeat(MAX_ACK_CHARS + 1), 3)).not.toBeNull();
  });

  it('does nothing when fact-checking is off — <message> is not checked either', () => {
    expect(ackOnlyRefusal('Итого 4088500 ₽ за месяц', 0)).toBeNull();
    expect(ackOnlyRefusal('а'.repeat(5000), 0)).toBeNull();
  });
});
