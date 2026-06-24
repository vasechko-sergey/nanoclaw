import { callMessages, extractJsonObject } from './llm.js';

export type CoveVerdict = 'supported' | 'uncertain' | 'contradicted';
export interface CoveResult { verdict: CoveVerdict; why: string; }

const MODEL = 'claude-haiku-4-5';

// Factored CoVe: the claim is verified in ISOLATION — the prompt deliberately
// contains no surrounding answer/context, so the model can't just agree with
// its own earlier framing. This surfaces confabulations re-reading wouldn't.
const SYSTEM = [
  'You independently fact-check a single CLAIM using only your own knowledge.',
  'Do not assume the claim is true. Judge it on its own.',
  'Return JSON ONLY: {"verdict":"supported|uncertain|contradicted","why":"<short>"}.',
  '- supported: you are confident it is true.',
  '- contradicted: you are confident it is false or misleading.',
  '- uncertain: you cannot confidently judge (niche, ambiguous, time-sensitive).',
].join('\n');

export function parseCoveVerdict(text: string): CoveResult {
  const json = extractJsonObject(text);
  if (json !== null) {
    try {
      const o = JSON.parse(json) as { verdict?: unknown; why?: unknown };
      if (o.verdict === 'supported' || o.verdict === 'contradicted' || o.verdict === 'uncertain') {
        return { verdict: o.verdict, why: typeof o.why === 'string' ? o.why : '' };
      }
    } catch { /* fall through */ }
  }
  return { verdict: 'uncertain', why: 'unparseable' };
}

export async function coveCheck(
  claim: string,
  fetchImpl: typeof fetch = globalThis.fetch,
  env: Record<string, string | undefined> = process.env,
): Promise<CoveResult> {
  const text = await callMessages({ system: SYSTEM, user: `CLAIM: ${claim}`, model: MODEL, maxTokens: 256 }, fetchImpl, env);
  return parseCoveVerdict(text);
}
