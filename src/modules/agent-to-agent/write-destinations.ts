/**
 * Project the agent's central `agent_destinations` rows into its per-session
 * `inbound.db` so the running container can resolve names locally. Called on
 * every container wake and after admin-time destination edits (e.g. create_agent).
 *
 * Core container-runner calls this via a dynamic import guarded by a
 * `hasTable('agent_destinations')` check — without the agent-to-agent module
 * installed, the central table doesn't exist and the projection is skipped.
 *
 * For an agent target the row also carries `a2a_kinds` — what THAT TARGET
 * accepts, read from the target's own `agents/<folder>/agent.json`. One file is
 * both the declaration the registry publishes to peers and the list the
 * transport gate enforces; splitting them is what let the protocol rot in the
 * first place. NULL means the target published no `a2a_in` declaration (absent
 * or malformed descriptor, or one that omits the field), which disarms the gate
 * for it. Re-read on every wake, so authoring a declaration takes effect without
 * a restart.
 */
import fs from 'fs';

import { getLegalKinds } from '../../agent-registry.js';
import { AGENTS_DIR } from '../../config.js';
import { getAgentGroup } from '../../db/agent-groups.js';
import { getMessagingGroup } from '../../db/messaging-groups.js';
import { replaceDestinations, type DestinationRow } from '../../db/session-db.js';
import { getSession } from '../../db/sessions.js';
import { log } from '../../log.js';
import { OWNER_PERSON_KEY, personKeyForChannel } from '../../person-key.js';
import { inboundDbPath, openInboundDb } from '../../session-manager.js';
import { getDestinations } from './db/agent-destinations.js';

export function writeDestinations(agentGroupId: string, sessionId: string): void {
  const dbPath = inboundDbPath(agentGroupId, sessionId);
  if (!fs.existsSync(dbPath)) return;

  // Channel destinations are scoped to the session's owner. The agent GROUP is
  // wired to every person it serves; a SESSION serves exactly one of them, and
  // an agent that can name a second human will eventually address them —
  // 2026-08-15, Payne answered the owner with `to="iphone"` and the reply went
  // to the other person's phone. Agent destinations are NOT filtered: a2a keeps
  // its own per-person routing (agent-route.ts stays within one owner_key).
  const ownerKey = getSession(sessionId)?.owner_key || OWNER_PERSON_KEY;
  const rows = getDestinations(agentGroupId);
  const resolved: DestinationRow[] = [];

  for (const row of rows) {
    if (row.target_type === 'channel') {
      const mg = getMessagingGroup(row.target_id);
      if (!mg) continue;
      if (personKeyForChannel(mg.channel_type, mg.platform_id) !== ownerKey) continue;
      resolved.push({
        name: row.local_name,
        display_name: mg.name ?? row.local_name,
        type: 'channel',
        channel_type: mg.channel_type,
        platform_id: mg.platform_id,
        agent_group_id: null,
        a2a_kinds: null,
      });
    } else if (row.target_type === 'agent') {
      const ag = getAgentGroup(row.target_id);
      if (!ag) continue;
      // What the TARGET accepts, from the target's own descriptor — the same
      // file the registry publishes to peers. null = no descriptor = gate off.
      const kinds = getLegalKinds(AGENTS_DIR, ag.folder);
      resolved.push({
        name: row.local_name,
        display_name: ag.name,
        type: 'agent',
        channel_type: null,
        platform_id: null,
        agent_group_id: ag.id,
        a2a_kinds: kinds === null ? null : JSON.stringify(kinds),
      });
    }
  }

  const db = openInboundDb(agentGroupId, sessionId);
  try {
    replaceDestinations(db, resolved);
  } finally {
    db.close();
  }
  log.debug('Destination map written', { sessionId, count: resolved.length });
}
