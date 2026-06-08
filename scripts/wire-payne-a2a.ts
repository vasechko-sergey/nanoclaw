/**
 * One-shot: wire Payne <-> Jarvis and Payne <-> Greg agent-to-agent
 * destinations. Adds four agent_destinations rows + reprojects any
 * currently-running parent sessions so the new destinations are visible
 * without a container restart.
 *
 * Idempotent — uses getDestinationByName to skip existing rows.
 *
 * Usage:
 *   pnpm exec tsx scripts/wire-payne-a2a.ts
 *
 * Pre-req: agent_groups rows for jarvis, payne, greg already exist
 * (run scripts/create-payne.ts first). For Jarvis/Greg this script assumes
 * their letter-ids on this install — adjust the constants if needed.
 */
import path from 'path';

import { DATA_DIR } from '../src/config.js';
import { initDb, getDb } from '../src/db/connection.js';
import { getAgentGroup } from '../src/db/agent-groups.js';
import { runMigrations } from '../src/db/migrations/index.js';
import {
  createDestination,
  getDestinationByName,
} from '../src/modules/agent-to-agent/db/agent-destinations.js';
import { writeDestinations } from '../src/modules/agent-to-agent/write-destinations.js';

// (from, local_name_for_destination, to)
const PAIRS: Array<[string, string, string]> = [
  ['jarvis', 'payne',  'payne'],
  ['payne',  'jarvis', 'jarvis'],
  ['greg',   'payne',  'payne'],
  ['payne',  'greg',   'greg'],
];

function main(): void {
  const db = initDb(path.join(DATA_DIR, 'v2.db'));
  runMigrations(db);

  // Validate all agent groups exist before any mutation.
  const involved = Array.from(new Set(PAIRS.flatMap(([f, , t]) => [f, t])));
  for (const id of involved) {
    if (!getAgentGroup(id)) {
      console.error(`agent_group not found: ${id}`);
      console.error('Run create-payne.ts and confirm jarvis/greg ids match this install.');
      process.exit(3);
    }
  }

  const now = new Date().toISOString();
  for (const [from, name, to] of PAIRS) {
    const existing = getDestinationByName(from, name);
    if (existing) {
      console.log(`destination already exists: ${from} -> ${name} (${to})`);
      continue;
    }
    createDestination({
      agent_group_id: from,
      local_name: name,
      target_type: 'agent',
      target_id: to,
      created_at: now,
    });
    console.log(`added destination: ${from} -> ${name} (${to})`);
  }

  // Reproject live sessions of any parent that just gained a destination,
  // so the running container picks up the new neighbour without restart.
  const parents = Array.from(new Set(PAIRS.map(([f]) => f)));
  const placeholders = parents.map(() => '?').join(',');
  const liveSessions = db
    .prepare(
      `SELECT id, agent_group_id FROM sessions
        WHERE agent_group_id IN (${placeholders})
          AND container_status = 'running'`
    )
    .all(...parents) as Array<{ id: string; agent_group_id: string }>;
  for (const s of liveSessions) {
    try {
      writeDestinations(s.agent_group_id, s.id);
      console.log(`reprojected destinations for ${s.agent_group_id} session ${s.id}`);
    } catch (err) {
      console.warn(`reproject failed for ${s.agent_group_id}/${s.id}: ${err instanceof Error ? err.message : err}`);
    }
  }

  console.log('done');
}

main();
