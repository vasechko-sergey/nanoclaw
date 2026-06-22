import type { FactualityGate } from '../config.js';

/**
 * Run the prose judge only when: gate is 'full', the turn produced tool output
 * (the judge's evidence), and the reply has enough prose to be worth judging
 * (≥ 6 words of letters — skips pure numbers, "ok", short acks).
 */
export function shouldJudgeProse(mode: FactualityGate, toolOutputText: string, messageText: string): boolean {
  if (mode !== 'full') return false;
  if (!toolOutputText.trim()) return false;
  const words = (messageText.match(/[A-Za-zА-Яа-яЁё]{2,}/g) ?? []).length;
  return words >= 6;
}
