/**
 * Agent-to-agent message routing.
 *
 * Outbound messages with `channel_type === 'agent'` target another agent
 * group rather than a channel. Permission is enforced via `agent_destinations` —
 * the source agent must have a row for the target. Content is copied into the
 * target's inbound DB; if the source message had `files` (from `send_file`),
 * the actual bytes are copied from the source's outbox into the target's
 * `inbox/<a2a-msg-id>/` directory and surfaced to the target agent as
 * `attachments` (existing formatter convention — see formatter.ts:230).
 * The target agent can then forward the file onward via its own `send_file`
 * call using the absolute `/workspace/inbox/<a2a-msg-id>/<filename>` path.
 *
 * Self-messages are always allowed (used for system notes injected back into
 * an agent's own session, e.g. post-approval follow-up prompts).
 *
 * Core delivery.ts dispatches into this via a dynamic import guarded by a
 * `channel_type === 'agent'` check. When the module is absent the check in
 * core throws with a "module not installed" message so retry → mark failed.
 */
import fs from 'fs';
import path from 'path';

import { validateA2aKind } from '../../../shared/a2a/kinds.js';
import { getLegalKinds } from '../../agent-registry.js';
import { isSafeAttachmentName } from '../../attachment-safety.js';
import { getAgentGroup } from '../../db/agent-groups.js';
import { getInboundA2aHops, getInboundSourceSessionId, getMostRecentPeerSourceSessionId } from '../../db/session-db.js';
import { getSession, getSessionsByAgentGroup } from '../../db/sessions.js';
import { AGENTS_DIR, OWNER_PERSON_KEY } from '../../config.js';
import { wakeContainer } from '../../container-runner.js';
import { log } from '../../log.js';
import { openInboundDb, resolveSession, sessionDir, writeSessionMessage } from '../../session-manager.js';
import type { Session } from '../../types.js';
import { hasDestination } from './db/agent-destinations.js';

export { isSafeAttachmentName };

/**
 * Maximum a2a forwards in a single chain. Anything past this is dropped with
 * a warning instead of forwarded — a guardrail against runaway agent-pair
 * loops (Greg→Jarvis→Greg→…). The number is deliberately small: ordinary
 * delegations are 1–2 hops (user → A → B, optional B → A reply). Anything
 * past 5 is a loop in practice.
 */
export const MAX_A2A_HOPS = 5;

export interface ForwardedAttachment {
  name: string;
  filename: string;
  type: 'file';
  localPath: string;
}

/**
 * Copy file attachments from the source agent's outbox into the target
 * agent's inbox. Returns attachments using the formatter's existing
 * `{name, type, localPath}` convention — target agent reads `localPath`
 * as relative to `/workspace/`, matching how channel-inbound attachments
 * are surfaced today.
 *
 * Missing source files and unsafe (path-traversal) filenames are skipped
 * with a warning rather than failing the whole route — a bad filename
 * reference shouldn't kill the accompanying text.
 */
export function forwardAttachedFiles(
  source: { agentGroupId: string; sessionId: string; messageId: string; filenames: string[] },
  target: { agentGroupId: string; sessionId: string; messageId: string },
): ForwardedAttachment[] {
  if (source.filenames.length === 0) return [];

  const sourceDir = path.join(sessionDir(source.agentGroupId, source.sessionId), 'outbox', source.messageId);
  if (!fs.existsSync(sourceDir)) {
    log.warn('agent-route: source outbox dir missing, no files forwarded', {
      sourceMsgId: source.messageId,
      sourceDir,
    });
    return [];
  }

  const targetInboxDir = path.join(sessionDir(target.agentGroupId, target.sessionId), 'inbox', target.messageId);
  fs.mkdirSync(targetInboxDir, { recursive: true });

  const attachments: ForwardedAttachment[] = [];
  for (const filename of source.filenames) {
    if (!isSafeAttachmentName(filename)) {
      log.warn('agent-route: rejecting unsafe attachment filename (path traversal attempt?)', {
        sourceMsgId: source.messageId,
        filename,
      });
      continue;
    }
    const src = path.join(sourceDir, filename);
    if (!fs.existsSync(src)) {
      log.warn('agent-route: referenced file missing in source outbox, skipped', {
        sourceMsgId: source.messageId,
        filename,
      });
      continue;
    }
    const dst = path.join(targetInboxDir, filename);
    fs.copyFileSync(src, dst);
    attachments.push({
      name: filename,
      filename,
      type: 'file',
      localPath: `inbox/${target.messageId}/${filename}`,
    });
  }
  return attachments;
}

export interface RoutableAgentMessage {
  id: string;
  platform_id: string | null;
  content: string;
  /**
   * For replies, the id of the inbound message being replied to. The
   * container's formatter sets this from the first inbound in the batch
   * (`container/agent-runner/src/formatter.ts`). Used here to route the
   * reply back to the originating session — see `resolveTargetSession`.
   */
  in_reply_to: string | null;
}

/**
 * Pick which session of `targetAgentGroupId` should receive this a2a message.
 *
 * SECURITY: agents are shared across people and memory is partitioned by
 * `session.owner_key`. Routing MUST stay within one person — the source
 * session's owner (`owner_key`, defaulting to OWNER_PERSON_KEY) determines
 * which owner's target session may receive the message. A candidate owned by
 * a different person is never returned; we fall through to an owner-scoped
 * session (existing or freshly created) instead.
 *
 * Three layers, highest-fidelity first — each owner-gated:
 *
 * 1. **Direct return-path** (in_reply_to lookup): if the message is a reply
 *    (`in_reply_to` set), open the source agent's inbound DB and read the
 *    triggering row's `source_session_id`. That column was stamped when the
 *    original outbound was routed — it's the session that started the
 *    conversation, and replies should land there when it is active AND owned
 *    by the same person.
 *
 * 2. **Peer-affinity fallback**: if (1) misses (in_reply_to is null or the
 *    referenced row isn't an a2a inbound), look up the most recent a2a
 *    inbound *from the target agent group* in source's inbound and use its
 *    `source_session_id`. Same owner gate applies to the candidate.
 *
 * 3. **Newest owner-scoped active session, else fresh**: pick the newest
 *    active session of the target group owned by this person. If none exists,
 *    create a fresh session stamped with this person's owner_key (never adopt
 *    another person's session).
 */
export function resolveTargetSession(
  msg: RoutableAgentMessage,
  sourceSession: Session,
  targetAgentGroupId: string,
): Session {
  const ownerKey = sourceSession.owner_key || OWNER_PERSON_KEY;
  const srcDb = openInboundDb(sourceSession.agent_group_id, sourceSession.id);
  let originSessionId: string | null = null;
  try {
    if (msg.in_reply_to) originSessionId = getInboundSourceSessionId(srcDb, msg.in_reply_to);
    if (!originSessionId) originSessionId = getMostRecentPeerSourceSessionId(srcDb, targetAgentGroupId);
  } finally {
    srcDb.close();
  }
  // Return-path / peer-affinity candidate — accept ONLY if it belongs to the
  // same person. A candidate owned by a different person would be a cross-user
  // leak; fall through to an owner-scoped session instead.
  if (originSessionId) {
    const candidate = getSession(originSessionId);
    if (
      candidate &&
      candidate.agent_group_id === targetAgentGroupId &&
      candidate.status === 'active' &&
      (candidate.owner_key || OWNER_PERSON_KEY) === ownerKey
    ) {
      return candidate;
    }
  }
  // Newest active session of the target group OWNED BY THIS PERSON.
  const owned = getSessionsByAgentGroup(targetAgentGroupId)
    .filter((s) => s.status === 'active' && (s.owner_key || OWNER_PERSON_KEY) === ownerKey)
    .sort((a, b) => b.created_at.localeCompare(a.created_at));
  if (owned[0]) return owned[0];
  // None yet — create a fresh session stamped with this owner_key. Use
  // 'per-thread' + null thread, NOT 'agent-shared': the agent-shared branch
  // reuses the newest active session of the group regardless of owner (via
  // findSessionByAgentGroup), which would adopt another person's session.
  // With messagingGroupId=null and sessionMode='per-thread', resolveSession
  // skips all reuse branches and creates a fresh session stamped with ownerKey.
  return resolveSession(targetAgentGroupId, null, null, 'per-thread', ownerKey).session;
}

/**
 * Stamp the source agent's identity onto forwarded a2a content.
 *
 * a2a payloads are agent-authored JSON (`{"action":"workout_done",…}`) and carry
 * no sender, so a relaying target would have to *recall* who sent it — which is
 * exactly how a peer's name ends up invented. Adding `sender` (the source's
 * canonical `agent_groups.name`) makes the container formatter render
 * `sender="Майор Пейн"` through its existing `content.sender` path.
 *
 * `agent_groups.name` is the ONLY name source — deliberately not duplicated
 * into any descriptor, since that duplication is the drift this fixes.
 *
 * Never clobbers a real (truthy) `sender`/`senderId`: system notes injected
 * back into a session set their own (`sender: 'system'`). A falsy sender
 * (null/empty) counts as unset and gets stamped. Non-JSON and non-object
 * content is returned unchanged — there is no object to stamp.
 */
export function stampSenderIdentity(content: string, sourceAgentGroupId: string): string {
  const group = getAgentGroup(sourceAgentGroupId);
  if (!group) return content;

  let parsed: unknown;
  try {
    parsed = JSON.parse(content);
  } catch {
    return content;
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return content;

  const obj = parsed as Record<string, unknown>;
  // Treat null/empty as unset, not as "already stamped": the formatter falls
  // back to "Unknown" on a falsy sender, which is the very gap this closes.
  // A real sender like 'system' is truthy and still preserved. Fall back to
  // the folder id if a group somehow has no name — naming the sender by id
  // still beats leaving the target to guess.
  if (!obj.sender) obj.sender = group.name || group.folder;
  if (!obj.senderId) obj.senderId = group.folder;
  return JSON.stringify(obj);
}

/**
 * Returns a human-readable reason when this message must not be routed, or null
 * when it is fine. Parse failures return null — a non-JSON content string has no
 * envelope to judge, and Layer 1 already saw it.
 */
function checkA2aKind(msg: RoutableAgentMessage, targetGroup: { folder: string; name: string }): string | null {
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(msg.content);
  } catch {
    return null;
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
  // System notes are injected by the host itself (approvals, restarts,
  // bounces). They are not agent-authored protocol and must always land —
  // this is also what stops a bounce from bouncing.
  if (parsed.sender === 'system') return null;

  const legal = getLegalKinds(AGENTS_DIR, targetGroup.folder);
  const verdict = validateA2aKind(
    typeof parsed.kind === 'string' ? parsed.kind : null,
    typeof parsed.text === 'string' ? parsed.text : '',
    legal,
  );
  if (verdict.ok) return null;

  const legalList = (legal ?? []).concat('text').join(', ');
  return verdict.code === 'unmarked_json'
    ? `Сообщение для «${targetGroup.name}» не доставлено: тело выглядит структурным, но kind= не указан. Легальные kind: ${legalList}.`
    : `Сообщение для «${targetGroup.name}» не доставлено: kind="${verdict.kind}" не принимается. Легальные kind: ${legalList}.`;
}

/**
 * Write the rejection into the SENDER's own inbound as a system self-note — the
 * established shape (container-restart.ts, approvals/primitive.ts). Without this
 * the message would die silently in the retry path, which is the "cuts live
 * traffic" failure the owner explicitly ruled out.
 *
 * No wakeContainer: the sender's container is by definition alive (it just
 * emitted this) and will see the note on its next poll. Waking it would race its
 * own turn.
 */
function bounceToSender(reason: string, msg: RoutableAgentMessage, session: Session): void {
  log.warn('Agent message rejected: illegal a2a kind', {
    from: session.agent_group_id,
    fromSession: session.id,
    sourceMsgId: msg.id,
    reason,
  });
  writeSessionMessage(session.agent_group_id, session.id, {
    id: `a2a-reject-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    kind: 'chat',
    timestamp: new Date().toISOString(),
    platformId: session.agent_group_id,
    channelType: 'agent',
    threadId: null,
    content: JSON.stringify({
      text: `<system>${reason} Исправь kind и перешли.</system>`,
      sender: 'system',
      senderId: 'system',
    }),
    sourceSessionId: session.id,
  });
}

export async function routeAgentMessage(msg: RoutableAgentMessage, session: Session): Promise<void> {
  const targetAgentGroupId = msg.platform_id;
  if (!targetAgentGroupId) {
    throw new Error(`agent-to-agent message ${msg.id} is missing a target agent group id`);
  }
  if (
    targetAgentGroupId !== session.agent_group_id &&
    !hasDestination(session.agent_group_id, 'agent', targetAgentGroupId)
  ) {
    throw new Error(
      `unauthorized agent-to-agent: ${session.agent_group_id} has no destination for ${targetAgentGroupId}`,
    );
  }
  const targetGroup = getAgentGroup(targetAgentGroupId);
  if (!targetGroup) {
    throw new Error(`target agent group ${targetAgentGroupId} not found for message ${msg.id}`);
  }

  // Layer 2 — the authoritative gate. Layer 1 (container poll-loop) catches
  // essentially everything in-turn with better context; this exists so the
  // declaration is BINDING: an emit path that skips poll-loop (MCP send_message,
  // an older agent-runner, anything future) is still checked. A gate with a
  // bypass is a document again, which is what we are replacing.
  const reject = checkA2aKind(msg, targetGroup);
  if (reject) {
    bounceToSender(reject, msg, session);
    return;
  }

  const targetSession = resolveTargetSession(msg, session, targetAgentGroupId);
  const a2aMsgId = `a2a-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

  // Compute and enforce hop cap. The source-side inbound row the outbound
  // is replying to (`in_reply_to`) carries the chain's current depth; the
  // new a2a inbound row is depth+1. If we'd exceed MAX_A2A_HOPS, drop the
  // message and log — better to break the chain than to let two agents
  // ping-pong forever burning tokens. First-hop reply from a channel-side
  // message has source_hops=0, so newHops=1: well under the cap.
  let sourceHops = 0;
  if (msg.in_reply_to) {
    const srcDb = openInboundDb(session.agent_group_id, session.id);
    try {
      sourceHops = getInboundA2aHops(srcDb, msg.in_reply_to);
    } finally {
      srcDb.close();
    }
  }
  const newHops = sourceHops + 1;
  if (newHops > MAX_A2A_HOPS) {
    log.warn('Agent message dropped: a2a hop cap exceeded', {
      from: session.agent_group_id,
      to: targetAgentGroupId,
      fromSession: session.id,
      sourceMsgId: msg.id,
      hops: newHops,
      cap: MAX_A2A_HOPS,
    });
    return;
  }

  // If the source message references files (via `send_file`), forward the
  // bytes from the source's outbox into the target's inbox so the target
  // agent can actually see and re-send them. Without this, agent-to-agent
  // file attachments look like they arrive but the target has no way to
  // read the bytes — they live in a session dir it doesn't mount.
  // Stamp the source agent's identity *after* file forwarding so the sender
  // fields survive that step's re-serialization.
  const forwardedContent = stampSenderIdentity(
    forwardFileAttachments(msg, a2aMsgId, session, targetAgentGroupId, targetSession.id),
    session.agent_group_id,
  );

  writeSessionMessage(targetAgentGroupId, targetSession.id, {
    id: a2aMsgId,
    kind: 'chat',
    timestamp: new Date().toISOString(),
    platformId: session.agent_group_id,
    channelType: 'agent',
    threadId: null,
    content: forwardedContent,
    sourceSessionId: session.id,
    a2aHops: newHops,
  });
  log.info('Agent message routed', {
    from: session.agent_group_id,
    to: targetAgentGroupId,
    targetSession: targetSession.id,
    a2aMsgId,
    hops: newHops,
    forwardedFileCount: countForwardedFiles(forwardedContent),
  });
  const fresh = getSession(targetSession.id);
  if (fresh) await wakeContainer(fresh);
}

/**
 * Parse source content, copy any referenced `files` from source outbox to
 * target inbox, and return a JSON string with an `attachments` array added
 * (formatter.ts:223 already knows how to render this shape).
 *
 * If the source content isn't JSON or has no files, returns the original
 * content string unchanged — this is safe to call on every route.
 */
function forwardFileAttachments(
  msg: RoutableAgentMessage,
  a2aMsgId: string,
  sourceSession: Session,
  targetAgentGroupId: string,
  targetSessionId: string,
): string {
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(msg.content);
  } catch {
    return msg.content;
  }
  const files = parsed.files as unknown;
  if (!Array.isArray(files) || files.length === 0) return msg.content;
  const filenames = files.filter((f): f is string => typeof f === 'string');
  if (filenames.length === 0) return msg.content;

  const attachments = forwardAttachedFiles(
    {
      agentGroupId: sourceSession.agent_group_id,
      sessionId: sourceSession.id,
      messageId: msg.id,
      filenames,
    },
    {
      agentGroupId: targetAgentGroupId,
      sessionId: targetSessionId,
      messageId: a2aMsgId,
    },
  );

  // Merge into any existing `attachments` (unlikely in a2a context but safe).
  const existing = Array.isArray(parsed.attachments) ? (parsed.attachments as Record<string, unknown>[]) : [];
  parsed.attachments = [...existing, ...attachments];

  return JSON.stringify(parsed);
}

function countForwardedFiles(contentStr: string): number {
  try {
    const parsed = JSON.parse(contentStr);
    return Array.isArray(parsed.attachments) ? parsed.attachments.length : 0;
  } catch {
    return 0;
  }
}
