/**
 * ≥ 6 words of letters — enough prose to be worth fact-checking (skips pure
 * numbers, "ok", short acks). Shared by the Phase-2 prose-judge trigger and the
 * Phase-3 L3 trigger so the threshold lives in one place.
 */
export function hasEnoughProse(text: string): boolean {
  return (text.match(/[A-Za-zА-Яа-яЁё]{2,}/g) ?? []).length >= 6;
}

/**
 * Run the prose judge only when: level >= 2 (tool-prose), the turn produced
 * tool output (the judge's evidence), and the reply has enough prose to be
 * worth judging.
 */
export function shouldJudgeProse(level: number, toolOutputText: string, messageText: string): boolean {
  if (level < 2) return false;
  if (!toolOutputText.trim()) return false;
  return hasEnoughProse(messageText);
}
