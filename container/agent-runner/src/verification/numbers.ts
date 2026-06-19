/**
 * Quantitative data-token extraction for the factuality gate (Phase 1).
 *
 * The gate grounds numeric claims: any number in an outbound message that
 * isn't present in this turn's tool outputs (or the user's own message) is
 * treated as ungrounded. To compare "$1.60" against "1.6" from a tool, both
 * sides run through the same normalize + extract pair.
 */

/**
 * Strip currency symbols, %, spaces, and thousands separators; return a
 * canonical numeric string (parseFloat round-trip, e.g. "1.60" -> "1.6").
 * Returns '' if the token isn't a plain number.
 */
export function normalizeNumber(token: string): string {
  const cleaned = token
    .replace(/[$€₽£¥]/g, '')
    .replace(/%/g, '')
    .replace(/\s/g, '')
    .replace(/,/g, '');
  if (!/^\d*\.?\d+$/.test(cleaned)) return '';
  const n = parseFloat(cleaned);
  if (Number.isNaN(n)) return '';
  return String(n);
}

// Matches currency-prefixed / spaced-grouped numbers, percentages, decimals,
// and bare integers. Ordered so the greedy grouped form wins before the bare
// single-digit fallback.
const TOKEN_RE = /[$€₽£¥]?\s?\d[\d.,\s]*\d|\d+(?:\.\d+)?%?|\d/g;

/**
 * Extract canonical data-numbers worth grounding. Phase-1 heuristic to bound
 * false positives: keep a number only if it carries a currency symbol, a %,
 * a decimal point, or has magnitude >= 100. Bare small integers (list counts,
 * "2 варианта", "3 подхода") are ignored — they're rarely fabricated data and
 * would otherwise flood the gate with false positives.
 */
export function extractDataNumbers(text: string): Set<string> {
  const out = new Set<string>();
  const matches = text.match(TOKEN_RE) ?? [];
  for (const raw of matches) {
    const trimmed = raw.trim();
    const hasCurrency = /[$€₽£¥]/.test(trimmed);
    const hasPercent = /%/.test(trimmed);
    const hasDecimal = /\d\.\d/.test(trimmed);
    const norm = normalizeNumber(trimmed);
    if (!norm) continue;
    const magnitudeBig = Math.abs(parseFloat(norm)) >= 100;
    if (hasCurrency || hasPercent || hasDecimal || magnitudeBig) {
      out.add(norm);
    }
  }
  return out;
}
