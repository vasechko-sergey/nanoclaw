import { extractClaims, L3_MAX_CLAIMS, type ExtractedClaim } from './claims.js';
import { coveCheck, type CoveVerdict } from './cove.js';
import { webVerify, type WebVerdict } from './web-verify.js';
import { checkProvenance } from './gate.js';
import { extractClaimedNumbers } from './numbers.js';

// A claim is already TOOL-GROUNDED when it carries data-numbers and every one
// traces to this turn's grounding set (exactly or as a rounding of a source
// value — checkProvenance). The value came from a script, not the model, so
// re-verifying it via CoVe/web is both wrong (private data isn't a web fact) and
// the source of an API-call burst that rate-limits the turn. No-number claims are
// never auto-grounded — those are the genuine external assertions L3 exists for.
export function isToolGrounded(claim: string, grounding: Set<string>): boolean {
  if (grounding.size === 0) return false;
  if (extractClaimedNumbers(claim).length === 0) return false;
  return checkProvenance(claim, grounding).grounded;
}

export const L3_MAX_WEB = 3;

export interface ClaimOutcome {
  claim: string;
  action_relevant: boolean;
  cove: CoveVerdict;
  web: WebVerdict | null; // null = not escalated
}

export interface Level3Result {
  failed: { claim: string; why: string }[]; // claims to bounce/hedge
  checked: number;
  escalated: number;
  /** Set only when the claim-extraction stage THREW (proxy/HTTP/timeout). Without
   *  this, a swallowed extractor error is indistinguishable from a legitimate
   *  empty result — both surface as `checked=0`, making a silently-dead L3 look
   *  identical to a healthy no-op. Callers log it so `checked=0 error=…` is a
   *  visible failure while a bare `checked=0` means "ran, found nothing". */
  error?: string;
}

/** Pure verdict aggregation (unit-tested in isolation). */
export function aggregateVerdicts(outcomes: ClaimOutcome[]): Level3Result {
  const failed: { claim: string; why: string }[] = [];
  let escalated = 0;
  for (const o of outcomes) {
    if (o.web !== null) escalated++;
    if (o.web === 'refuted') { failed.push({ claim: o.claim, why: 'web sources refute it' }); continue; }
    if (o.web === 'supported') continue; // web confirmed → pass
    // web is now 'unavailable' (escalated, no result) or null (not escalated:
    // non-action, or action but the web budget was exhausted). An action-relevant
    // claim CoVe flagged that we could NOT web-confirm must hedge, not silently
    // pass — that's the whole point of L3. (Covers both the degrade path and
    // budget-exhausted action claims symmetrically.)
    if (o.action_relevant && (o.cove === 'uncertain' || o.cove === 'contradicted')) {
      failed.push({
        claim: o.claim,
        why: o.cove === 'contradicted' ? 'flagged by an independent check, web could not confirm' : 'action-relevant and could not be verified',
      });
      continue;
    }
    // Non-action: only a confident CoVe contradiction fails (no web for non-action).
    if (o.cove === 'contradicted') { failed.push({ claim: o.claim, why: 'independent check contradicts it' }); continue; }
    // else pass: cove 'supported', or non-action 'uncertain'
  }
  return { failed, checked: outcomes.length, escalated };
}

/**
 * Full L3 pass: extract → CoVe each → escalate (action ∧ uncertain/contradicted)
 * to web (capped) → aggregate. fetchImpl/env injectable for tests. Any error in a
 * single stage degrades that claim toward 'pass' (fail-soft) — callers never block
 * delivery on an L3 error; they only act on `failed`.
 */
export async function runLevel3(
  replyText: string,
  sourcesText: string,
  grounding: Set<string> = new Set(),
  fetchImpl: typeof fetch = globalThis.fetch,
  env: Record<string, string | undefined> = process.env,
): Promise<Level3Result> {
  let claims: ExtractedClaim[] = [];
  try { claims = await extractClaims(replyText, sourcesText, fetchImpl, env); }
  catch (e) { return { failed: [], checked: 0, escalated: 0, error: 'extract: ' + (e instanceof Error ? e.message : String(e)) }; }

  const outcomes: ClaimOutcome[] = [];
  let webBudget = L3_MAX_WEB;
  for (const c of claims.slice(0, L3_MAX_CLAIMS)) {
    // Tool-grounded claims skip CoVe + web entirely — no API calls for values
    // that already came from this turn's script/tool output.
    if (isToolGrounded(c.claim, grounding)) {
      outcomes.push({ claim: c.claim, action_relevant: c.action_relevant, cove: 'supported', web: null });
      continue;
    }
    let cove: CoveVerdict = 'uncertain';
    try { cove = (await coveCheck(c.claim, fetchImpl, env)).verdict; } catch { cove = 'uncertain'; }
    let web: WebVerdict | null = null;
    if (c.action_relevant && (cove === 'uncertain' || cove === 'contradicted') && webBudget > 0) {
      webBudget--;
      try { web = (await webVerify(c.claim, fetchImpl, env)).verdict; } catch { web = 'unavailable'; }
    }
    outcomes.push({ claim: c.claim, action_relevant: c.action_relevant, cove, web });
  }
  return aggregateVerdicts(outcomes);
}
