/**
 * Direct route from a channel adapter that already resolved which agent
 * the inbound message addresses (e.g. iOS-app multi-agent picker). Bypasses
 * routeInbound's trigger-fanout; still runs sender resolution + access gate
 * + session resolve + write + wake so the dropped_messages audit trail and
 * permissions checks stay intact.
 */
import { getAgentGroup } from './db/agent-groups.js';
import { recordDroppedMessage } from './db/dropped-messages.js';
import { getMessagingGroupByPlatform } from './db/messaging-groups.js';
import { getSession } from './db/sessions.js';
import { log } from './log.js';
import { getAccessGate, getSenderResolver } from './router.js';
import { resolveSession, writeSessionMessage } from './session-manager.js';
import { wakeContainer } from './container-runner.js';
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

  const agentGroup = getAgentGroup(agentGroupId);
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
    const gate = accessGate(event, userId, mg, agentGroupId);
    if (!gate.allowed) {
      return { delivered: false, reason: gate.reason };
    }
  }

  const sessionMode: SessionMode = opts.sessionMode ?? 'shared';
  const { session } = resolveSession(agentGroupId, mg.id, event.threadId, sessionMode);
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
