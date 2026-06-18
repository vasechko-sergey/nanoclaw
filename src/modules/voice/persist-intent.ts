import { getDb } from '../../db/connection.js';
import { resolveVoiceIntent } from './voice-intent.js';

export interface PersistVoiceIntentResult {
  voiceIntent: boolean;
  hasIosContext: boolean;
  respondByVoice: boolean | null;
  groupVoiceMode: boolean;
}

/**
 * Compute the voice intent for a session from the inbound message content +
 * the messaging group's voice_mode default, then persist it on
 * sessions.voice_intent.
 *
 * Called from BOTH inbound paths so they cannot drift:
 *   - router.deliverToAgent  (routeInbound trigger fanout — Telegram etc.)
 *   - adapterRouteToAgent    (iOS-app direct route)
 *
 * iOS-app messages only ever go through the adapter path, and that is where
 * `respond_by_voice` actually arrives — so persisting intent in only one path
 * (the original bug) meant iOS voice replies never fired.
 */
export function persistVoiceIntent(input: {
  sessionId: string;
  messagingGroupId: string;
  content: string;
}): PersistVoiceIntentResult {
  let parsed: { ios_context?: { respond_by_voice?: boolean } | null } = {};
  try {
    parsed = JSON.parse(input.content);
  } catch {
    // non-JSON content (plain-text fallback) — ios_context absent
  }
  const iosContext = parsed.ios_context ?? null;
  const mgVoiceRow = getDb()
    .prepare('SELECT voice_mode FROM messaging_groups WHERE id = ?')
    .get(input.messagingGroupId) as { voice_mode: number } | undefined;
  const groupVoiceMode = (mgVoiceRow?.voice_mode ?? 0) !== 0;
  const voiceIntent = resolveVoiceIntent({ iosContext, groupVoiceMode });
  getDb()
    .prepare('UPDATE sessions SET voice_intent = ? WHERE id = ?')
    .run(voiceIntent ? 1 : 0, input.sessionId);
  return {
    voiceIntent,
    hasIosContext: !!iosContext,
    respondByVoice: iosContext?.respond_by_voice ?? null,
    groupVoiceMode,
  };
}
