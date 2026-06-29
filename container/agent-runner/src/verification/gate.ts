import { extractClaimedNumbers } from './numbers.js';

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
 *
 * Separator-grouped tokens get a decomposition escape hatch: "100,200,300"
 * fuses to a phantom "100200300" the agent never wrote, doom-looping the gate.
 * If a token's value isn't grounded, we treat it as grounded when every
 * component group is — i.e. it was a LIST whose items each trace to a source.
 * A real thousands-grouped number can't slip through this way: it always has a
 * <100 group (leading digit or "000") that the magnitude filter never admits to
 * the grounding set. When a list is only partly grounded we flag the real
 * offending parts, never the alien fused phantom.
 */
export function checkProvenance(body: string, grounding: Set<string>): ProvenanceResult {
  const groundNums = [...grounding].map(Number).filter((n) => !Number.isNaN(n));
  const isGrounded = (x: string) => grounding.has(x) || groundedByRounding(x, groundNums);
  const ungrounded: string[] = [];
  for (const { norm, parts } of extractClaimedNumbers(body)) {
    if (isGrounded(norm)) continue;
    const atoms = parts.length >= 2 ? parts : [norm];
    for (const a of atoms) if (!isGrounded(a)) ungrounded.push(a);
  }
  return { grounded: ungrounded.length === 0, ungrounded };
}
