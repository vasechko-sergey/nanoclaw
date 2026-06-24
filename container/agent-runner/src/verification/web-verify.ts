import { callMessages, extractJsonObject } from './llm.js';

export type WebVerdict = 'supported' | 'refuted' | 'unavailable';
export interface WebResult { verdict: WebVerdict; evidence: string; }

const MODEL = 'claude-haiku-4-5';
const WEB_TIMEOUT_MS = 30_000;
const TOOLS = [{ type: 'web_search_20250305', name: 'web_search', max_uses: 3 }];

const SYSTEM = [
  'Verify the CLAIM against current web sources. Use the web_search tool.',
  'Return JSON ONLY at the end: {"verdict":"supported|refuted","evidence":"<one line + source>"}.',
  '- supported: sources confirm it.',
  '- refuted: sources contradict it or it cannot be substantiated.',
].join('\n');

// Process-wide preflight latch: once the tool is known unavailable, stop trying.
let preflightFailed = false;
export function resetWebPreflight(): void { preflightFailed = false; }

export function parseWebVerdict(text: string): WebResult {
  const json = extractJsonObject(text);
  if (json !== null) {
    try {
      const o = JSON.parse(json) as { verdict?: unknown; evidence?: unknown };
      if (o.verdict === 'supported' || o.verdict === 'refuted') {
        return { verdict: o.verdict, evidence: typeof o.evidence === 'string' ? o.evidence : '' };
      }
    } catch { /* fall through */ }
  }
  return { verdict: 'unavailable', evidence: '' };
}

/**
 * Harness-side web verification. If the proxy/account doesn't serve the
 * web_search tool (non-200 or a thrown error), latch unavailable and no-op
 * thereafter — the L3 pipeline degrades to CoVe-only.
 */
export async function webVerify(
  claim: string,
  fetchImpl: typeof fetch = globalThis.fetch,
  env: Record<string, string | undefined> = process.env,
): Promise<WebResult> {
  if (preflightFailed) return { verdict: 'unavailable', evidence: '' };
  try {
    const text = await callMessages(
      { system: SYSTEM, user: `CLAIM: ${claim}`, model: MODEL, maxTokens: 1024, tools: TOOLS, timeoutMs: WEB_TIMEOUT_MS },
      fetchImpl, env,
    );
    return parseWebVerdict(text);
  } catch {
    preflightFailed = true;
    return { verdict: 'unavailable', evidence: '' };
  }
}
