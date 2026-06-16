/**
 * Idempotent host-startup bootstrap of the iOS team agents.
 *
 * Ensures `jarvis`/`payne`/`greg`/`gordon`/`scrooge` agent_groups +
 * container_configs rows exist. For every ios-app-v2 messaging_group, wires each as
 * `messaging_group_agents` (which auto-creates the channel destination so the
 * agent can reply) and eager-creates one session per agent so the adapter
 * routing path always finds a session even before the first inbound message.
 * Writes the bootstrap inbound system message for payne, greg, gordon, and
 * scrooge on freshly-created sessions so they prime their context without a
 * chat reply.
 */
import { randomUUID } from 'node:crypto';

import { createAgentGroup, getAgentGroupByFolder } from './db/agent-groups.js';
import { ensureContainerConfig } from './db/container-configs.js';
import {
  createMessagingGroupAgent,
  getAllMessagingGroups,
  getMessagingGroupAgentByPair,
} from './db/messaging-groups.js';
import { createSession, findSessionForAgent, updateSession } from './db/sessions.js';
import { personKeyForPlatform } from './channels/ios-app/v2/token-registry.js';
import { OWNER_PERSON_KEY } from './config.js';
import { initSessionFolder, writeSessionMessage } from './session-manager.js';
import { log } from './log.js';

const TEAM = [
  { id: 'jarvis', name: 'Jarvis', folder: 'jarvis', bootstrap: null as string | null },
  {
    id: 'payne',
    name: 'Майор Пейн',
    folder: 'payne',
    bootstrap:
      '[bootstrap] Прочитай INDEX.md, /workspace/global/identity.md и memories/self/profile.md. Дальше работай как обычно — без рапорта, без приветствия. Молчи до явного запроса пользователя.',
  },
  {
    id: 'greg',
    name: 'Dr House (Greg)',
    folder: 'greg',
    bootstrap:
      '[bootstrap] Прочитай INDEX.md, /workspace/global/identity.md и memories/self/. Молчи до явного запроса пользователя или явной аномалии в данных.',
  },
  {
    id: 'gordon',
    name: 'Гордон Рамзи',
    folder: 'gordon',
    bootstrap:
      '[bootstrap] Прочитай memories/index.md, /workspace/global/identity.md и /workspace/global/about.md. Дальше работай как обычно — без рапорта, без приветствия. Молчи до явного запроса пользователя.',
  },
  {
    id: 'scrooge',
    name: 'Scrooge',
    folder: 'scrooge',
    bootstrap:
      '[bootstrap] Прочитай memories/index.md, /workspace/global/identity.md и /workspace/global/about.md. Дальше работай как обычно — без рапорта, без приветствия. Молчи до явного запроса пользователя.',
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
    // Owner of this device's sessions. An ios-app-v2 mg's platform_id maps 1:1
    // to a person via the ios_tokens registry (minted at provisioning, before
    // this bootstrap runs). Stamping owner_key here is the isolation boundary
    // for eager-created sessions: without it they carry owner_key=null and
    // buildMounts falls back to OWNER_PERSON_KEY, mounting the OWNER's memory
    // into a second person's session. null (no token yet) keeps owner-fallback.
    const deviceOwner = mg.platform_id ? personKeyForPlatform(mg.platform_id) : null;
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
      if (existing) {
        // Backfill: a known non-owner person's eager session created before its
        // token existed (null owner → would mount the owner's memory). Stamp the
        // real owner so the next spawn isolates correctly. Owner's own device
        // (deviceOwner === OWNER_PERSON_KEY) and tokenless mgs are left alone.
        if (deviceOwner && deviceOwner !== OWNER_PERSON_KEY && existing.owner_key == null) {
          updateSession(existing.id, { owner_key: deviceOwner });
          log.info('bootstrap-trio backfilled eager session owner', {
            session: existing.id,
            owner: deviceOwner,
            mg: mg.id,
          });
        }
      } else {
        const newSessId = generateSessionId();
        createSession({
          id: newSessId,
          agent_group_id: canonicalId,
          messaging_group_id: mg.id,
          thread_id: null,
          owner_key: deviceOwner,
          agent_provider: null,
          status: 'active',
          container_status: 'stopped',
          last_active: null,
          created_at: new Date().toISOString(),
        });
        log.info('bootstrap-trio eager-created session', { sessionId: newSessId, agent: canonicalId, mg: mg.id });
        // Every eager-created session needs its on-disk folder + DB schemas so
        // the adapter routing path can write inbound messages to it. This MUST
        // run for all agents, not only those with a bootstrap prompt: agents
        // without one (e.g. jarvis, bootstrap=null) previously got an active
        // session row with no folder, so every inbound threw "Cannot open
        // database because the directory does not exist". initSessionFolder
        // both mkdirs and applies the inbound/outbound schemas.
        initSessionFolder(canonicalId, newSessId);
        if (entry.bootstrap) {
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
