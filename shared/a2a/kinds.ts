/**
 * The a2a envelope verdict — is this (kind, body) pair legal for this target?
 *
 * Lives in `shared/` because BOTH the host (`src/`, Node) and the agent
 * container (`container/agent-runner/`, Bun) must agree on it, and it is the
 * one artifact that decides what the a2a wire accepts. The host imports it by
 * relative path; the container resolves it through the `@shared/*` alias
 * (`container/agent-runner/tsconfig.json`), which Bun honors at runtime — the
 * same mechanism `shared/ios-app-protocol` already uses.
 *
 * It is deliberately NOT duplicated per tree. This project exists because a2a
 * contracts lived as prose that nothing checked, so they drifted from reality;
 * a hand-synced copy of the contract's own decision function would reproduce
 * that failure one layer down.
 *
 * Pure: no DB, no fs, no logging.
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
 *                    `[]` is NOT `null`: a descriptor that declares no kinds
 *                    ARMS the gate text-only — every other kind bounces. Only
 *                    `null` disarms. Never normalize a missing descriptor to
 *                    `[]`.
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
  // A JSON text starting with `{` can only parse to a plain object — never an
  // array, scalar, or null. So a successful parse here IS an object; no further
  // shape check is reachable. The cheap prefix test also keeps JSON.parse off
  // the hot path: ordinary prose never reaches it.
  if (!trimmed.startsWith('{')) return false;
  try {
    JSON.parse(trimmed);
  } catch {
    return false;
  }
  return true;
}
