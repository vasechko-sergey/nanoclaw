import { callMessages, extractJsonObject } from './llm.js';

export interface ExtractedClaim { claim: string; action_relevant: boolean; }

const MODEL = 'claude-haiku-4-5';
export const L3_MAX_CLAIMS = 6;

const SYSTEM = [
  'You extract checkable factual claims from an assistant REPLY for fact-checking.',
  "You are given the REPLY and the SOURCES (this turn's tool/script output).",
  'RULES:',
  '- List only CHECKABLE, falsifiable factual assertions (a fact about the world, a number+unit, a named entity attribute).',
  '- SKIP: opinions, plans, hedged/uncertain statements, questions, and anything already supported by SOURCES',
  '  (those are checked elsewhere — only surface claims that do NOT come from the sources).',
  '- Mark action_relevant=true when acting on the claim being wrong could harm: health/medical, money/finance,',
  '  schedule/time-critical, or an irreversible action. Otherwise false.',
  '- Return JSON ONLY: {"claims":[{"claim":"...","action_relevant":true|false}]}. Empty list if none.',
].join('\n');

export function parseClaims(text: string, max: number): ExtractedClaim[] {
  const json = extractJsonObject(text);
  if (json === null) return [];
  let obj: { claims?: unknown };
  try { obj = JSON.parse(json); } catch { return []; }
  const list = Array.isArray(obj.claims) ? obj.claims : [];
  return list
    .filter((c): c is { claim: string; action_relevant?: unknown } => !!c && typeof (c as { claim?: unknown }).claim === 'string')
    .map((c) => ({ claim: c.claim, action_relevant: c.action_relevant === true }))
    .slice(0, max);
}

export async function extractClaims(
  replyText: string,
  sourcesText: string,
  fetchImpl: typeof fetch = globalThis.fetch,
  env: Record<string, string | undefined> = process.env,
): Promise<ExtractedClaim[]> {
  const user = `SOURCES:\n${sourcesText || '(none)'}\n\nREPLY:\n${replyText}`;
  const text = await callMessages({ system: SYSTEM, user, model: MODEL }, fetchImpl, env);
  return parseClaims(text, L3_MAX_CLAIMS);
}
