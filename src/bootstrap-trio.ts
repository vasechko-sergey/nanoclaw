/**
 * Idempotent host-startup bootstrap of the iOS team agents.
 *
 * Ensures `jarvis`/`payne`/`greg`/`gordon` agent_groups + container_configs
 * rows exist. For every ios-app-v2 messaging_group, wires each as
 * `messaging_group_agents` (which auto-creates the channel destination so the
 * agent can reply) and eager-creates one session per agent so the adapter
 * routing path always finds a session even before the first inbound message.
 * Writes the bootstrap inbound system message for payne, greg, and gordon on
 * freshly-created sessions so they prime their context without a chat reply.
 */
import { randomUUID } from 'node:crypto';

import { createAgentGroup, getAgentGroupByFolder } from './db/agent-groups.js';
import { ensureContainerConfig } from './db/container-configs.js';
import {
  createMessagingGroupAgent,
  getAllMessagingGroups,
  getMessagingGroupAgentByPair,
} from './db/messaging-groups.js';
import { createSession, findSessionForAgent } from './db/sessions.js';
import { initSessionFolder, writeSessionMessage } from './session-manager.js';
import { log } from './log.js';

const TEAM = [
  { id: 'jarvis', name: 'Jarvis', folder: 'jarvis', bootstrap: null as string | null },
  {
    id: 'payne',
    name: 'Майор Пейн',
    folder: 'payne',
    bootstrap:
      '[bootstrap] Прочитай INDEX.md и memories/self/profile.md. Дальше работай как обычно — без рапорта, без приветствия. Молчи до явного запроса Сергея.',
  },
  {
    id: 'greg',
    name: 'Dr House (Greg)',
    folder: 'greg',
    bootstrap:
      '[bootstrap] Прочитай INDEX.md и memories/self/. Молчи до явного запроса Сергея или явной аномалии в данных.',
  },
  {
    id: 'gordon',
    name: 'Гордон Рамзи',
    folder: 'gordon',
    bootstrap:
      '[bootstrap] Прочитай memories/index.md и /workspace/global/about-sergei.md. Дальше работай как обычно — без рапорта, без приветствия. Молчи до явного запроса Сергея.',
  },
] as const;

function generateSessionId(): string {
  return `sess-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

export function bootstrapTrio(): void {
  // Resolve canonical agent_group ids. If an agent already exists for this
  // folder (legacy installs created Jarvis with a UUID id rather than the
  // slug `jarvis`), reuse its row id everywhere downstream — otherwise
  // ensureContainerConfig and the wiring/session rows fail with
  // FOREIGN KEY constraint failed.
  const canonicalIdByFolder = new Map<string, string>();
  for (const entry of TEAM) {
    const existing = getAgentGroupByFolder(entry.folder);
    if (existing) {
      canonicalIdByFolder.set(entry.folder, existing.id);
    } else {
      createAgentGroup({
        id: entry.id,
        name: entry.name,
        folder: entry.folder,
        agent_provider: null,
        created_at: new Date().toISOString(),
      });
      canonicalIdByFolder.set(entry.folder, entry.id);
      log.info('bootstrap-trio created agent_group', { id: entry.id });
    }
    ensureContainerConfig(canonicalIdByFolder.get(entry.folder)!);
  }

  const ios = getAllMessagingGroups().filter((m) => m.channel_type === 'ios-app-v2');
  for (const mg of ios) {
    let priority = 0;
    for (const entry of TEAM) {
      const canonicalId = canonicalIdByFolder.get(entry.folder)!;
      if (!getMessagingGroupAgentByPair(mg.id, canonicalId)) {
        createMessagingGroupAgent({
          id: `mga-${randomUUID()}`,
          messaging_group_id: mg.id,
          agent_group_id: canonicalId,
          // 'pattern' + engage_pattern '.' is the "match every message" sentinel
          // (see types.ts MessagingGroupAgent.engage_pattern doc).
          engage_mode: 'pattern',
          engage_pattern: '.',
          sender_scope: 'all',
          ignored_message_policy: 'drop',
          session_mode: 'shared',
          priority: priority++,
          created_at: new Date().toISOString(),
        });
        log.info('bootstrap-trio wired agent to mg', { mg: mg.id, agent: canonicalId });
      }
      const existing = findSessionForAgent(canonicalId, mg.id, null);
      if (!existing) {
        const newSessId = generateSessionId();
        createSession({
          id: newSessId,
          agent_group_id: canonicalId,
          messaging_group_id: mg.id,
          thread_id: null,
          agent_provider: null,
          status: 'active',
          container_status: 'stopped',
          last_active: null,
          created_at: new Date().toISOString(),
        });
        log.info('bootstrap-trio eager-created session', { sessionId: newSessId, agent: canonicalId, mg: mg.id });
        if (entry.bootstrap) {
          // writeSessionMessage opens inbound.db at the session folder path,
          // which requires the folder to exist — initSessionFolder both mkdirs
          // and applies the inbound/outbound schemas.
          initSessionFolder(canonicalId, newSessId);
          writeSessionMessage(canonicalId, newSessId, {
            id: `bootstrap-${randomUUID()}`,
            kind: 'system',
            timestamp: new Date().toISOString(),
            platformId: null,
            channelType: null,
            threadId: null,
            content: JSON.stringify({ subtype: 'bootstrap', text: entry.bootstrap }),
            trigger: 0,
          });
        }
      }
    }
  }
}
