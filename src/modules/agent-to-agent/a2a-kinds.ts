/**
 * The a2a envelope verdict — is this (kind, body) pair legal for this target?
 *
 * Pure by design: no DB, no fs, no logging. Both gate layers (container
 * poll-loop and host agent-route) call it, and neither can share a module with
 * the other — the host is Node/pnpm and the container is Bun, separate package
 * trees. `container/agent-runner/src/a2a-kinds.ts` is a deliberate mirror of
 * this file; change both together.
 *
 * See docs/superpowers/specs/2026-07-16-a2a-protocol-normalization-design.md.
 */

export type A2aKindVerdict =
  | { ok: true; kind: string }
  | { ok: false; code: 'unknown_kind' | 'unmarked_json'; kind: string };

/**
 * @param kind        the `kind=` attribute, or null/undefined/'' when omitted
 * @param body        the message body
 * @param legalKinds  the TARGET's declared kinds, or `null` when the target has
 *                    no descriptor — in which case the gate is DISARMED and
 *                    everything passes. This is not laxity: it is what lets the
 *                    code ship inert and lets each agent.json arm its own agent.
 *                    A malformed descriptor must also land here (fail open), so
 *                    that a typo cannot bounce all of an agent's traffic.
 */
export function validateA2aKind(
  kind: string | null | undefined,
  body: string,
  legalKinds: string[] | null,
): A2aKindVerdict {
  const k = kind || 'text';
  if (legalKinds === null) return { ok: true, kind: k };

  if (k === 'text') {
    // The forgotten-attribute case: an agent means to send `set_log`, omits the
    // attribute, and the structured payload sails through as prose. Silent
    // misclassification is exactly the failure this design exists to make loud.
    // Prose that is incidentally a valid JSON *object* does not occur; arrays
    // and scalars are not the drift risk, so only objects bounce.
    return isJsonObject(body) ? { ok: false, code: 'unmarked_json', kind: 'text' } : { ok: true, kind: 'text' };
  }

  // `text` is always legal and never declared — otherwise every descriptor
  // carries the same boilerplate line, and boilerplate stops being read.
  if (!legalKinds.includes(k)) return { ok: false, code: 'unknown_kind', kind: k };
  return { ok: true, kind: k };
}

function isJsonObject(body: string): boolean {
  const trimmed = body.trim();
  if (!trimmed.startsWith('{')) return false;
  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return false;
  }
  return parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed);
}
