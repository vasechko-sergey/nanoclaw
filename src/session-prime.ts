/**
 * Re-priming a session whose conversation was reset.
 *
 * `/new` clears the SDK continuation on purpose — the point is a clean thread.
 * But an agent's knowledge of the owner does not live in the thread: it lives in
 * `/workspace/global/about.md` (shared, Jarvis-written) and the agent's own
 * `memories/`. Those files exist precisely so a reset does not cost the owner
 * their history. Each agent's CLAUDE.md asks it to read them at the start of a
 * new conversation, and on 2026-08-24 Scrooge simply didn't: it answered a
 * budget question straight from the ledger and called the owner's girlfriend his
 * ex-wife, opening about.md only after being corrected. Prose in an instruction
 * file loses to a concrete question in front of it.
 *
 * So the host states it as work instead of hoping: one accumulate-only row, put
 * in front of whatever the owner types next.
 */
import { log } from './log.js';
import { writeSessionMessage } from './session-manager.js';

export const SESSION_RESET_PRIME =
  '[reset] Контекст разговора сброшен, но не память. До ответа на следующее сообщение молча прочитай ' +
  '/workspace/global/identity.md, /workspace/global/about.md и memories/index.md (а по теме вопроса — ' +
  'файл, на который index указывает). Не рапортуй о прочтении и не здоровайся — просто отвечай, уже зная.';

/**
 * Queue the durable-memory re-read for the session's next container.
 *
 * `trigger: 0` — accumulate only: this row must not wake a container by itself
 * (a reset is not a reason to spawn one), it rides the owner's next message.
 * `onWake: 1` — only a FRESH container's first poll may take it, so the
 * container dying from the reset cannot swallow it on the way out.
 *
 * Never throws: a failure here must not break the reset the user asked for.
 */
export function primeSessionAfterReset(agentGroupId: string, sessionId: string): void {
  try {
    writeSessionMessage(agentGroupId, sessionId, {
      id: `prime-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
      kind: 'chat',
      timestamp: new Date().toISOString(),
      platformId: agentGroupId,
      channelType: 'agent',
      threadId: null,
      content: JSON.stringify({ text: SESSION_RESET_PRIME, sender: 'system', senderId: 'system' }),
      trigger: 0,
      onWake: 1,
    });
  } catch (err) {
    log.warn('Failed to prime session after reset', { sessionId, agentGroupId, err });
  }
}
