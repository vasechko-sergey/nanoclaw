/**
 * Force CLAUDE.md / skill changes to take effect on running agents.
 *
 * SDK sessions resume via `continuation:claude` rows in outbound.db — that
 * means instructions are only loaded at session BIRTH. Restarting the
 * container alone does NOT help (it restarts mid-conversation). We need:
 *
 *   1. Kill the container.
 *   2. DELETE the continuation row(s) from outbound.db so the next start
 *      is a fresh session that reads the new CLAUDE.md.
 *
 * The container respawns naturally on the next user message; we don't force
 * a respawn here — that would race the kill, and skills are also re-symlinked
 * on spawn (`syncSkillSymlinks` in container-runner.ts) so we want the next
 * spawn to be clean.
 *
 * Usage:
 *   pnpm exec tsx scripts/reload-claude-md.ts <folder> [<folder>...]
 *   pnpm exec tsx scripts/reload-claude-md.ts payne greg scrooge jarvis
 */
import path from 'path';

import { DATA_DIR } from '../src/config.js';
import { initDb, getDb } from '../src/db/connection.js';
import { getAgentGroupByFolder } from '../src/db/agent-groups.js';
import { runMigrations } from '../src/db/migrations/index.js';
import { killContainer, clearSessionContinuation } from '../src/container-runner.js';

async function main(): Promise<void> {
  const folders = process.argv.slice(2);
  if (folders.length === 0) {
    console.error('usage: reload-claude-md.ts <folder> [<folder>...]');
    process.exit(2);
  }

  initDb(path.join(DATA_DIR, 'v2.db'));
  runMigrations(getDb());

  for (const folder of folders) {
    const ag = getAgentGroupByFolder(folder);
    if (!ag) {
      console.error(`agent_group not found for folder: ${folder}`);
      continue;
    }
    const sessions = getDb()
      .prepare(
        `SELECT id FROM sessions
          WHERE agent_group_id = ?
            AND container_status = 'running'`
      )
      .all(ag.id) as Array<{ id: string }>;

    if (sessions.length === 0) {
      console.log(`${folder}: no running sessions, only clearing continuation in stored sessions`);
    }

    // Also clear continuation for any session that ever existed for this
    // agent group, not just running ones — a stopped container that still
    // has a continuation row would resume into the old prompt on next wake.
    const allSessions = getDb()
      .prepare(`SELECT id FROM sessions WHERE agent_group_id = ?`)
      .all(ag.id) as Array<{ id: string }>;

    for (const s of sessions) {
      try {
        await killContainer(ag.id, s.id);
        console.log(`${folder}: killed container for session ${s.id}`);
      } catch (err) {
        console.warn(`${folder}: kill failed for ${s.id}: ${err instanceof Error ? err.message : err}`);
      }
    }

    for (const s of allSessions) {
      try {
        clearSessionContinuation(ag.id, s.id);
        console.log(`${folder}: cleared continuation for ${s.id}`);
      } catch (err) {
        console.warn(`${folder}: clear continuation failed for ${s.id}: ${err instanceof Error ? err.message : err}`);
      }
    }
  }

  console.log('done — next user message will spawn a fresh container reading the updated CLAUDE.md');
}

void main();
