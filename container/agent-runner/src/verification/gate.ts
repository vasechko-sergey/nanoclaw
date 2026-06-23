import { extractDataNumbers } from './numbers.js';

export interface ProvenanceResult {
  grounded: boolean;
  /** Canonical numbers present in the message but absent from the grounding set. */
  ungrounded: string[];
}

/**
 * A claimed number is grounded if it appears in the grounding set exactly, OR
 * if it is a source number rounded to the precision the message displays —
 * e.g. the message shows "$12009" or "$12009.3" while the tool output had
 * "12009.34". Rounding for presentation is not fabrication; only a value that
 * is no rounding of any source number is flagged (e.g. "$12500" vs 12009.34).
 */
function groundedByRounding(claimed: string, groundNums: number[]): boolean {
  const cv = Number(claimed);
  if (Number.isNaN(cv)) return false;
  const dec = (claimed.split('.')[1] ?? '').length;
  const m = 10 ** dec;
  return groundNums.some((g) => Math.round(g * m) / m === cv);
}

/**
 * A message body is grounded iff every data-number in it traces to the grounding
 * set (this turn's tool outputs ∪ the user's own message) — exactly or as a
 * rounding of a source number. Phase 1 is numeric-only; prose is Phase 2.
 */
export function checkProvenance(body: string, grounding: Set<string>): ProvenanceResult {
  const claimed = extractDataNumbers(body);
  const groundNums = [...grounding].map(Number).filter((n) => !Number.isNaN(n));
  const ungrounded: string[] = [];
  for (const n of claimed) {
    if (grounding.has(n)) continue;
    if (groundedByRounding(n, groundNums)) continue;
    ungrounded.push(n);
  }
  return { grounded: ungrounded.length === 0, ungrounded };
}
