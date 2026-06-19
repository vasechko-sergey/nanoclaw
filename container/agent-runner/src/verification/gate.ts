import { extractDataNumbers } from './numbers.js';

export interface ProvenanceResult {
  grounded: boolean;
  /** Canonical numbers present in the message but absent from the grounding set. */
  ungrounded: string[];
}

/**
 * A message body is grounded iff every data-number in it also appears in the
 * grounding set (this turn's tool outputs ∪ the user's own message). Phase 1
 * is numeric-only — prose claims are out of scope until Phase 2 (see spec).
 */
export function checkProvenance(body: string, grounding: Set<string>): ProvenanceResult {
  const claimed = extractDataNumbers(body);
  const ungrounded: string[] = [];
  for (const n of claimed) {
    if (!grounding.has(n)) ungrounded.push(n);
  }
  return { grounded: ungrounded.length === 0, ungrounded };
}
