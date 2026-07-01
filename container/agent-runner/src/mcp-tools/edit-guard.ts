/**
 * Guard for `edit_message`: distinguish a genuine CORRECTION (fix a number, a
 * typo, a wrong clause — a small delta) from REPURPOSING a bubble to deliver new
 * content (a list, a fresh answer — a near-total rewrite / large append). The
 * latter must be a new `send_message`, never an edit: editing an old message
 * moves the new content back to that message's timestamp, which reorders the
 * chat and hides the update. This is what went wrong when Scrooge edited an old
 * message to deliver a balances list.
 *
 * The signal is character-level change. Two knobs:
 *  - MIN_COMPARE_LEN: below this (both old and new are short), skip the check.
 *    Short messages are cheap to resend and their ratios are unstable — a
 *    3-char fix on a 5-char message reads as a "total" change. The abuse we care
 *    about always involves volume (a long new body), so the gate only needs to
 *    bite once a message is substantial.
 *  - MAX_CHANGE_RATIO: normalized Levenshtein distance above which the edit is a
 *    replacement, not a correction. A large append inflates the distance too, so
 *    one ratio catches both full rewrites and "stuff a list onto the end".
 */
export const MIN_COMPARE_LEN = 40;
export const MAX_CHANGE_RATIO = 0.6;

/** Normalized Levenshtein distance in [0,1]: 0 = identical, 1 = nothing shared. */
export function changeRatio(a: string, b: string): number {
  if (a === b) return 0;
  const al = a.length;
  const bl = b.length;
  if (al === 0 || bl === 0) return 1;
  return levenshtein(a, b) / Math.max(al, bl);
}

/**
 * True when `next` is a replacement of `prev` rather than a correction — i.e.
 * the edit should have been a new message. Short messages (both ends below
 * MIN_COMPARE_LEN) are exempt; an empty `prev` is exempt (nothing to compare).
 */
export function isReplacementEdit(prev: string, next: string): boolean {
  const p = prev.trim();
  const n = next.trim();
  if (p.length === 0) return false;
  if (Math.max(p.length, n.length) < MIN_COMPARE_LEN) return false;
  return changeRatio(p, n) > MAX_CHANGE_RATIO;
}

/** Space-optimized Levenshtein (two rolling rows → O(min(n,m)) memory). */
function levenshtein(a: string, b: string): number {
  if (a.length < b.length) [a, b] = [b, a];
  const m = b.length;
  let prev = new Array<number>(m + 1);
  let curr = new Array<number>(m + 1);
  for (let j = 0; j <= m; j++) prev[j] = j;
  for (let i = 1; i <= a.length; i++) {
    curr[0] = i;
    const ai = a.charCodeAt(i - 1);
    for (let j = 1; j <= m; j++) {
      const cost = ai === b.charCodeAt(j - 1) ? 0 : 1;
      curr[j] = Math.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost);
    }
    [prev, curr] = [curr, prev];
  }
  return prev[m];
}
