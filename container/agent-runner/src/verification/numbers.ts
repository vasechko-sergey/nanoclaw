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

// Matches currency-prefixed / grouped numbers, percentages, decimals, and bare
// integers. Grouping is STRICT — a separator must precede EXACTLY 3 digits (real
// thousands grouping like "1,234" / "1 000 000"). This is deliberate: a loose
// `\d[\d.,\s]*\d` fused comma/space-separated LISTS ("9, 11, 16") into a phantom
// number ("91116") that no tool output could ever ground, doom-looping the
// factuality gate. Grouped form is listed first so it wins over the bare fallback.
const TOKEN_RE = /[$€₽£¥]?\s?\d{1,3}(?:[,\s]\d{3})+(?:\.\d+)?%?|[$€₽£¥]?\s?\d+(?:\.\d+)?%?/g;

/**
 * Phase-1 keep filter applied to one matched token: return its canonical value
 * iff it's worth grounding (currency symbol, %, decimal point, or magnitude
 * >= 100), else null. Bare small integers (list counts, "2 варианта",
 * "3 подхода") are ignored — rarely fabricated data, would flood the gate.
 */
function keptNumber(raw: string): string | null {
  const trimmed = raw.trim();
  const hasCurrency = /[$€₽£¥]/.test(trimmed);
  const hasPercent = /%/.test(trimmed);
  const hasDecimal = /\d\.\d/.test(trimmed);
  const norm = normalizeNumber(trimmed);
  if (!norm) return null;
  const magnitudeBig = Math.abs(parseFloat(norm)) >= 100;
  return hasCurrency || hasPercent || hasDecimal || magnitudeBig ? norm : null;
}

/**
 * Split a matched token into its normalized component groups, but ONLY when it
 * is separator-grouped (>= 2 groups joined by comma/space). Returns [] for a
 * single-group token. "100,200,300" -> ["100","200","300"]; "1,234,567" ->
 * ["1","234","567"]; "$12009.34" -> [] (one group).
 */
function splitParts(raw: string): string[] {
  const cleaned = raw.replace(/[$€₽£¥%]/g, '').trim();
  const pieces = cleaned.split(/[,\s]+/).filter(Boolean);
  if (pieces.length < 2) return [];
  const norms = pieces.map(normalizeNumber);
  if (norms.some((n) => n === '')) return [];
  return norms;
}

/**
 * Extract canonical data-numbers worth grounding. Phase-1 heuristic to bound
 * false positives (see keptNumber). Returns the canonical set; for the
 * decomposition-aware form used by the gate, see extractClaimedNumbers.
 */
export function extractDataNumbers(text: string): Set<string> {
  const out = new Set<string>();
  for (const raw of text.match(TOKEN_RE) ?? []) {
    const norm = keptNumber(raw);
    if (norm) out.add(norm);
  }
  return out;
}

export interface ClaimedNumber {
  /** Canonical fused value, e.g. "100,200,300" -> "100200300". */
  norm: string;
  /**
   * Normalized component groups when the token is separator-grouped (>= 2),
   * else []. The gate uses these to tell a comma/space LIST ("100,200,300",
   * fused into a phantom) from a real thousands-grouped number: a real number
   * always carries a <100 group (its leading group, or a "000"), which the
   * magnitude filter never admits to the grounding set — so it can never
   * decompose into an all-grounded list, while a genuine list can.
   */
  parts: string[];
}

/**
 * Like extractDataNumbers, but preserves each kept token's component groups so
 * the gate can recognize separator-fused lists. One entry per matched token
 * (not deduped — the gate folds duplicates itself).
 */
export function extractClaimedNumbers(text: string): ClaimedNumber[] {
  const out: ClaimedNumber[] = [];
  for (const raw of text.match(TOKEN_RE) ?? []) {
    const norm = keptNumber(raw);
    if (!norm) continue;
    out.push({ norm, parts: splitParts(raw) });
  }
  return out;
}
