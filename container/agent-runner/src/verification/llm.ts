type EnvLike = Record<string, string | undefined>;

export interface MessagesCall {
  system: string;
  user: string;
  model: string;
  maxTokens?: number;
  /** Anthropic Tool[] shape (e.g. web_search server tool). Typed loosely until a concrete caller pins it. */
  tools?: unknown[];
  timeoutMs?: number;
}

const DEFAULT_TIMEOUT_MS = 20_000;

/**
 * Pull a JSON object out of a model's freeform text. Models often wrap the
 * object in a ```json fence and/or surround it with prose that itself contains
 * braces — a naive first-`{`-to-last-`}` slice then swallows the fence backticks
 * or stray prose braces and JSON.parse chokes (observed in production:
 * "Unrecognized token '`'"). So: prefer the contents of a fenced code block,
 * then brace-match from the first `{` to its balanced `}` (string-aware).
 */
export function extractJsonObject(text: string): string | null {
  const fence = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const hay = fence ? fence[1] : text;
  const start = hay.indexOf('{');
  if (start === -1) return null;
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < hay.length; i++) {
    const ch = hay[i];
    if (inStr) { if (esc) esc = false; else if (ch === '\\') esc = true; else if (ch === '"') inStr = false; }
    else if (ch === '"') inStr = true;
    else if (ch === '{') depth++;
    else if (ch === '}') { depth--; if (depth === 0) return hay.slice(start, i + 1); }
  }
  return null;
}

/** One raw Messages API call through the credential proxy. Returns concatenated text blocks. */
export async function callMessages(
  call: MessagesCall,
  fetchImpl: typeof fetch = globalThis.fetch,
  env: EnvLike = process.env,
): Promise<string> {
  const base = env.ANTHROPIC_BASE_URL;
  if (!base) throw new Error('llm: ANTHROPIC_BASE_URL not set');
  const headers: Record<string, string> = { 'content-type': 'application/json', 'anthropic-version': '2023-06-01' };
  if (env.ANTHROPIC_API_KEY) {
    headers['x-api-key'] = env.ANTHROPIC_API_KEY;
  } else {
    headers['authorization'] = `Bearer ${env.CLAUDE_CODE_OAUTH_TOKEN ?? env.ANTHROPIC_AUTH_TOKEN ?? 'placeholder'}`;
    headers['anthropic-beta'] = 'oauth-2025-04-20';
  }
  const body: Record<string, unknown> = {
    model: call.model,
    max_tokens: Math.max(1, call.maxTokens ?? 1024),
    system: call.system,
    messages: [{ role: 'user', content: call.user }],
  };
  if (call.tools) body.tools = call.tools;
  const res = await fetchImpl(`${base}/v1/messages`, {
    method: 'POST',
    signal: AbortSignal.timeout(call.timeoutMs ?? DEFAULT_TIMEOUT_MS),
    headers,
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`llm: HTTP ${res.status}`);
  const data = (await res.json()) as { content?: { type: string; text?: string }[] };
  return (data.content ?? []).filter((b) => b.type === 'text' && typeof b.text === 'string').map((b) => b.text as string).join('');
}
