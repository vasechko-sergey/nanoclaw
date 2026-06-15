/**
 * Direct route from a channel adapter that already resolved which agent
 * the inbound message addresses (e.g. iOS-app multi-agent picker). Bypasses
 * routeInbound's trigger-fanout; still runs sender resolution + access gate
 * + session resolve + write + wake so the dropped_messages audit trail and
 * permissions checks stay intact.
 */
import { gateCommand } from './command-gate.js';
import { getAgentGroup, getAgentGroupByFolder } from './db/agent-groups.js';
import { recordDroppedMessage } from './db/dropped-messages.js';
import { getMessagingGroupByPlatform } from './db/messaging-groups.js';
import { getSession } from './db/sessions.js';
import { log } from './log.js';
import { resolvePersonKey } from './person-key.js';
import { getAccessGate, getSenderResolver } from './router.js';
import { resolveSession, writeOutboundDirect, writeSessionMessage } from './session-manager.js';
import { killContainer, wakeContainer, clearSessionContinuation, isContainerRunning } from './container-runner.js';
import { startTypingRefresh, stopTypingRefresh } from './modules/typing/index.js';
import type { InboundEvent } from './channels/adapter.js';

type SessionMode = 'shared' | 'per-thread' | 'agent-shared';

export interface AdapterRouteOpts {
  wake?: boolean;
  sessionMode?: SessionMode;
}

export interface AdapterRouteResult {
  delivered: boolean;
  reason?: string;
  sessionId?: string;
}

export async function adapterRouteToAgent(
  event: InboundEvent,
  agentGroupId: string,
  opts: AdapterRouteOpts = {},
): Promise<AdapterRouteResult> {
  const mg = getMessagingGroupByPlatform(event.channelType, event.platformId);
  if (!mg) {
    log.warn('adapterRouteToAgent: no messaging group', {
      channelType: event.channelType,
      platformId: event.platformId,
    });
    return { delivered: false, reason: 'no_messaging_group' };
  }

  const agentGroup = getAgentGroup(agentGroupId) ?? getAgentGroupByFolder(agentGroupId);
  if (!agentGroup) {
    log.warn('adapterRouteToAgent: unknown agent group', { agentGroupId });
    recordDroppedMessage({
      channel_type: event.channelType,
      platform_id: event.platformId,
      user_id: null,
      sender_name: null,
      reason: 'unknown_agent',
      messaging_group_id: mg.id,
      agent_group_id: agentGroupId,
    });
    return { delivered: false, reason: 'unknown_agent' };
  }

  const senderResolver = getSenderResolver();
  const userId: string | null = senderResolver ? senderResolver(event) : null;

  const accessGate = getAccessGate();
  if (accessGate) {
    const gate = accessGate(event, userId, mg, agentGroup.id);
    if (!gate.allowed) {
      return { delivered: false, reason: gate.reason };
    }
  }

  const sessionMode: SessionMode = opts.sessionMode ?? 'shared';

  // Host-side command gate. Mirrors router.ts deliverToAgent so /new etc.
  // get handled at the host instead of being shipped to the container as
  // plain text — the Claude Code SDK's own slash handling can stall for
  // minutes on /new (it tries to summarize/clear in-band), while a host
  // kill-and-resolve cycle is sub-second.
  if (event.message.kind === 'chat' || event.message.kind === 'chat-sdk') {
    const gate = gateCommand(event.message.content, userId, agentGroup.id);
    if (gate.action === 'filter') {
      log.debug('adapterRouteToAgent: filtered command dropped', { agentGroupId: agentGroup.id });
      return { delivered: false, reason: 'filtered_command' };
    }
    if (gate.action === 'new_session') {
      // Reset IN PLACE. Resolve the exact session the next message would land
      // on (mode-aware — the previous code looked the session up by the raw
      // event.threadId, which misses under 'shared' mode where the session's
      // thread_id is null, so the old session was reused with its SDK
      // continuation intact and /new only *looked* like a reset). Kill the
      // container and wipe the persisted `continuation:%` so the next wake
      // starts a brand-new conversation (fresh CLAUDE.md, no replayed context).
      // Clear AFTER the container exits so the dying writer can't re-persist it.
      const { session: target } = resolveSession(
        agentGroup.id,
        mg.id,
        event.threadId,
        sessionMode,
        resolvePersonKey(userId),
      );
      const clearContinuation = (): void => clearSessionContinuation(target.agent_group_id, target.id);
      const wasRunning = isContainerRunning(target.id);
      killContainer(target.id, '/new command', clearContinuation);
      if (!wasRunning) clearContinuation();
      log.info('Session reset by /new', { sessionId: target.id, agentGroupId: agentGroup.id });
      writeOutboundDirect(target.agent_group_id, target.id, {
        id: `new-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
        kind: 'chat',
        platformId: event.platformId,
        channelType: event.channelType,
        threadId: event.threadId,
        content: JSON.stringify({ text: 'Контекст сброшен. Начинаем с чистого листа.' }),
      });
      return { delivered: true, sessionId: target.id };
    }
    if (gate.action === 'rewrite') {
      event = {
        ...event,
        message: { ...event.message, content: JSON.stringify({ text: gate.text }) },
      };
    }
    if (gate.action === 'deny') {
      const { session: denySession } = resolveSession(
        agentGroup.id,
        mg.id,
        event.threadId,
        sessionMode,
        resolvePersonKey(userId),
      );
      writeOutboundDirect(denySession.agent_group_id, denySession.id, {
        id: `deny-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
        kind: 'chat',
        platformId: event.platformId,
        channelType: event.channelType,
        threadId: event.threadId,
        content: JSON.stringify({ text: `Permission denied: ${gate.command} requires admin access.` }),
      });
      log.info('adapterRouteToAgent: admin command denied', {
        command: gate.command,
        userId,
        agentGroupId: agentGroup.id,
      });
      return { delivered: false, reason: 'denied' };
    }
  }

  const { session } = resolveSession(agentGroup.id, mg.id, event.threadId, sessionMode, resolvePersonKey(userId));
  const wake = opts.wake !== false;

  writeSessionMessage(session.agent_group_id, session.id, {
    id: event.message.id,
    kind: event.message.kind,
    timestamp: event.message.timestamp,
    platformId: event.platformId,
    channelType: event.channelType,
    threadId: event.threadId,
    content: event.message.content,
    trigger: wake ? 1 : 0,
  });

  if (wake) {
    startTypingRefresh(session.id, session.agent_group_id, event.channelType, event.platformId, event.threadId);
    const fresh = getSession(session.id);
    if (fresh) {
      const woke = await wakeContainer(fresh);
      if (!woke) stopTypingRefresh(fresh.id);
    }
  }

  return { delivered: true, sessionId: session.id };
}
