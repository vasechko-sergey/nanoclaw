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
