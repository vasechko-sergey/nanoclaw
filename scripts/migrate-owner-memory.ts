/**
 * One-time: move the owner's memory out of groups/<folder>/ and the per-agent-
 * group .claude-shared into data/user-memory/<OWNER_PERSON_KEY>/<folder>/, so
 * the owner-aware buildMounts finds it. Idempotent per path (skips if target
 * exists). Run with --dry-run first.
 *
 * WARNING — BACK UP BEFORE RUNNING:
 *   This script uses renameSync (MOVE), not copy. After a real run the source
 *   directories are permanently gone — there is no in-place rollback. Always
 *   back up groups/ and data/ before running without --dry-run.
 *
 * WARNING — STOP THE NANOCLAW SERVICE FIRST:
 *   If the host is running while this script executes, a container spawn can
 *   call initUserMemory and pre-create empty target directories. The
 *   skip-if-target-exists guard will then SKIP those entire subdirectories,
 *   silently leaving the real source data orphaned in the old location. Stop
 *   the service (launchctl unload … or systemctl --user stop nanoclaw) before
 *   running so nothing races in.
 *
 *   pnpm exec tsx scripts/migrate-owner-memory.ts --dry-run
 *   pnpm exec tsx scripts/migrate-owner-memory.ts
 */
import fs from 'fs';
import path from 'path';
import { DATA_DIR, GROUPS_DIR, OWNER_PERSON_KEY } from '../src/config.js';
import { initDb } from '../src/db/connection.js';
import { getAllAgentGroups } from '../src/db/agent-groups.js';
import { MEMORY_SUBDIRS, userMemoryRoot, userGlobalRoot } from '../src/user-memory.js';

const dryRun = process.argv.includes('--dry-run');
// initDb requires the central DB path (it is not no-arg). getAllAgentGroups is
// exported from src/db/agent-groups.ts — both verified against the codebase.

function move(src: string, dst: string): void {
  if (!fs.existsSync(src)) return;
  if (fs.existsSync(dst)) {
    console.log(`SKIP (target exists): ${dst}`);
    return;
  }
  console.log(`${dryRun ? 'WOULD MOVE' : 'MOVE'}: ${src} -> ${dst}`);
  if (dryRun) return;
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.renameSync(src, dst);
}

initDb(path.join(DATA_DIR, 'v2.db'));
const key = OWNER_PERSON_KEY;
for (const ag of getAllAgentGroups()) {
  const groupDir = path.join(GROUPS_DIR, ag.folder);
  const memRoot = userMemoryRoot(key, ag.folder);
  for (const sub of MEMORY_SUBDIRS) {
    move(path.join(groupDir, sub), path.join(memRoot, sub));
  }
  move(path.join(DATA_DIR, 'v2-sessions', ag.id, '.claude-shared'), path.join(memRoot, '.claude'));
}
// Shared global → owner's per-person global.
const oldGlobal = path.join(GROUPS_DIR, 'global');
const newGlobal = userGlobalRoot(key);
for (const entry of fs.existsSync(oldGlobal) ? fs.readdirSync(oldGlobal) : []) {
  move(path.join(oldGlobal, entry), path.join(newGlobal, entry));
}
console.log(dryRun ? 'Dry run complete.' : 'Migration complete.');
