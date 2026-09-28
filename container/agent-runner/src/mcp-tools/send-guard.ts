/**
 * Guard for `send_message` to a PERSON while the factuality gate is on.
 *
 * The gate checks `<message>` blocks only: the poll-loop holds them until the
 * turn's verdict and bounces ungrounded numbers / unsupported claims. This tool
 * writes straight to messages_out, so anything sent through it reaches the
 * person unchecked. Jarvis (2026-09-27) did exactly that after a bounce — the
 * full answer and a price table went out this way, and 5 of the 6 send_message
 * calls to a person in the month before carried figures. Legitimate use is a
 * short mid-turn acknowledgement ("on it, checking…"); that must stay instant.
 *
 * So: while the gate is on, a message to a person passes only if it is short
 * and carries no figure the gate would check (same extractor as the gate —
 * currency, %, decimals, magnitude >= 100). Anything else is refused at once
 * and the agent is pointed at its `<message>` reply, where every level of the
 * check applies. Agent-to-agent traffic is not the person's and is untouched.
 */
import { extractDataNumbers } from '../verification/numbers.js';

/** Longest acknowledgement that may skip the gate — a sentence or two, never an answer. */
export const MAX_ACK_CHARS = 200;

/**
 * Why `text` may not go to a person via send_message at this factuality level,
 * or null when it may. Level 0 means the gate is off and nothing is checked on
 * any path, so there is nothing to bypass.
 */
export function ackOnlyRefusal(text: string, factualityLevel: number): string | null {
  if (factualityLevel < 1) return null;
  const len = text.trim().length;
  const figures = [...extractDataNumbers(text)];
  if (len <= MAX_ACK_CHARS && figures.length === 0) return null;
  const reasons: string[] = [];
  if (len > MAX_ACK_CHARS) reasons.push(`it is ${len} characters`);
  if (figures.length > 0) reasons.push(`it has figures (${figures.slice(0, 5).join(', ')})`);
  return (
    `Not sent: ${reasons.join(' and ')}. While fact-checking is on, send_message to a person is only for a ` +
    `short acknowledgement (at most ${MAX_ACK_CHARS} characters, no figures) — nothing sent this way is ` +
    `fact-checked. Put this in your <message> reply instead: it is checked and delivered there.`
  );
}
