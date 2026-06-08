/**
 * One-shot: create the `payne` agent_group on this NanoClaw install.
 *
 * Why this exists (and why we don't use `ncl groups create` for this):
 *   `ncl groups create` generates auto-ids (often digit-leading) which
 *   break OneCLI's letter-leading id requirement and cause container
 *   spawn 400s. This script writes the row directly with id="payne".
 *   It also calls `ensureContainerConfig`, which `ncl create` doesn't,
 *   so the first spawn doesn't fail with "Container config not found".
 *
 * Idempotent — re-running is a no-op if the rows already exist.
 *
 * Usage:
 *   pnpm exec tsx scripts/create-payne.ts
 *
 * Pre-req: groups/payne/ folder skeleton must already exist (CLAUDE.md,
 * constraints.md, muscle_groups.md, profile.md, exercises/, programs/,
 * sessions/, memories/). The container won't crash if these are missing,
 * but the agent will have nothing to read at startup.
 */
import path from 'path';

import { DATA_DIR } from '../src/config.js';
import { createAgentGroup, getAgentGroup } from '../src/db/agent-groups.js';
import { initDb } from '../src/db/connection.js';
import { ensureContainerConfig } from '../src/db/container-configs.js';
import { runMigrations } from '../src/db/migrations/index.js';

const ID = 'payne';
const NAME = 'Майор Пейн';
const FOLDER = 'payne';

function main(): void {
  const db = initDb(path.join(DATA_DIR, 'v2.db'));
  runMigrations(db); // idempotent

  if (getAgentGroup(ID)) {
    console.log(`agent_group ${ID} already exists — skipping createAgentGroup`);
  } else {
    createAgentGroup({
      id: ID,
      name: NAME,
      folder: FOLDER,
      agent_provider: null,
      created_at: new Date().toISOString(),
    });
    console.log(`created agent_group ${ID} (folder=${FOLDER})`);
  }

  ensureContainerConfig(ID);
  console.log(`ensured container_configs row for ${ID}`);
}

main();
