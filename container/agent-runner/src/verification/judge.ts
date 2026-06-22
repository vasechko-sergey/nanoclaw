export interface ProseVerdict {
  unsupported: { claim: string; why: string }[];
}

const JUDGE_SYSTEM = [
  'You are a fact-checker. You are given an assistant REPLY and the SOURCES it had',
  'available this turn (tool/script outputs). Find claims in the REPLY that draw on',
  'the SOURCES but are NOT supported by them (contradicted, or stated with specifics',
  'the sources do not contain).',
  '',
  'RULES:',
  '- Only judge claims that depend on the SOURCES. IGNORE general world knowledge not',
  '  derived from the sources (e.g. "USDT is a stablecoin") — do NOT list them.',
  '- A claim that accurately restates or summarizes the sources is supported.',
  '- If unsure whether a claim is source-derived, treat it as supported (do not list it).',
  '- Return JSON only: {"unsupported":[{"claim":"...","why":"..."}]}. Empty list if all',
  '  source-derived claims are supported.',
].join('\n');

export function buildJudgePrompt(replyText: string, sourcesText: string): { system: string; user: string } {
  const user = `SOURCES:\n${sourcesText || '(no tool output this turn)'}\n\nREPLY:\n${replyText}`;
  return { system: JUDGE_SYSTEM, user };
}

/** Extract the first JSON object from the model's text and validate the shape. */
export function parseJudgeVerdict(text: string): ProseVerdict {
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start === -1 || end === -1 || end < start) throw new Error('judge: no JSON object in response');
  const obj = JSON.parse(text.slice(start, end + 1)) as { unsupported?: unknown };
  const list = Array.isArray(obj.unsupported) ? obj.unsupported : [];
  const unsupported = list
    .filter((x): x is { claim: string; why?: string } => !!x && typeof (x as { claim?: unknown }).claim === 'string')
    .map((x) => ({ claim: x.claim, why: typeof x.why === 'string' ? x.why : '' }));
  return { unsupported };
}

const HAIKU_MODEL = 'claude-haiku-4-5';

type EnvLike = Record<string, string | undefined>;

/**
 * One-shot prose-grounding judge. Raw Messages API call through the host
 * credential proxy (NOT the Agent SDK). fetchImpl + env are injectable for tests.
 * Throws on network error, non-200, or unparseable body — caller applies
 * fail-closed-soft.
 */
export async function judgeProse(
  replyText: string,
  sourcesText: string,
  fetchImpl: typeof fetch = globalThis.fetch,
  env: EnvLike = process.env,
): Promise<ProseVerdict> {
  const base = env.ANTHROPIC_BASE_URL;
  if (!base) throw new Error('judge: ANTHROPIC_BASE_URL not set');
  const { system, user } = buildJudgePrompt(replyText, sourcesText);

  const headers: Record<string, string> = {
    'content-type': 'application/json',
    'anthropic-version': '2023-06-01',
  };
  if (env.ANTHROPIC_API_KEY) {
    headers['x-api-key'] = env.ANTHROPIC_API_KEY; // proxy re-injects the real key
  } else {
    headers['authorization'] = `Bearer ${env.CLAUDE_CODE_OAUTH_TOKEN ?? env.ANTHROPIC_AUTH_TOKEN ?? 'placeholder'}`;
    headers['anthropic-beta'] = 'oauth-2025-04-20'; // proxy swaps the Bearer token
  }

  const res = await fetchImpl(`${base}/v1/messages`, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      model: HAIKU_MODEL,
      max_tokens: 1024,
      system,
      messages: [{ role: 'user', content: user }],
    }),
  });
  if (!res.ok) throw new Error(`judge: HTTP ${res.status}`);
  const data = (await res.json()) as { content?: { type: string; text?: string }[] };
  const text = (data.content ?? [])
    .filter((b) => b.type === 'text' && typeof b.text === 'string')
    .map((b) => b.text as string)
    .join('');
  return parseJudgeVerdict(text);
}
