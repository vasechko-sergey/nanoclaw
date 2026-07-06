/**
 * One-off ops: re-time frozen pending recurring tasks onto the owner's current
 * timezone.
 *
 * Context: the fix "recurrence resolves owner tz for null owner_key" corrects
 * how the NEXT occurrence of a recurring task is computed. But occurrences that
 * were already frozen by the buggy code keep the wrong (host-TIMEZONE) fire
 * time until they fire once and self-correct — for a travelling owner that's
 * one more mis-timed brief. This recomputes every still-pending recurring row
 * with the same logic handleRecurrence now uses and rewrites process_after in
 * place.
 *
 * Idempotent: a row already at the correct next-run is skipped, so it is safe
 * to re-run. Run with the host STOPPED so the single-writer-per-inbound.db
 * invariant holds (the sweep also writes these files).
 *
 *   pnpm exec tsx scripts/renudge-recurrence.ts --dry   # preview, no writes
 *   pnpm exec tsx scripts/renudge-recurrence.ts         # apply
 */
import fs from 'node:fs';
import path from 'node:path';

import { CronExpressionParser } from 'cron-parser';

import { DATA_DIR, OWNER_PERSON_KEY, TIMEZONE } from '../src/config.js';
import { initDb } from '../src/db/connection.js';
import { getActiveSessions } from '../src/db/sessions.js';
import { resolveOwnerTz } from '../src/modules/person-tz/index.js';
import { inboundDbPath, openInboundDb } from '../src/session-manager.js';

const dry = process.argv.includes('--dry');
initDb(path.join(DATA_DIR, 'v2.db'));

let changed = 0;
for (const s of getActiveSessions()) {
  const dbFile = inboundDbPath(s.agent_group_id, s.id);
  if (!fs.existsSync(dbFile)) continue;
  const db = openInboundDb(s.agent_group_id, s.id);
  try {
    const rows = db
      .prepare("SELECT id, recurrence, process_after FROM messages_in WHERE status = 'pending' AND recurrence IS NOT NULL")
      .all() as Array<{ id: string; recurrence: string; process_after: string }>;
    if (rows.length === 0) continue;

    const tz = resolveOwnerTz(s.owner_key || OWNER_PERSON_KEY) ?? TIMEZONE;
    for (const r of rows) {
      const next = CronExpressionParser.parse(r.recurrence, { tz }).next().toISOString();
      if (new Date(next).getTime() === new Date(r.process_after).getTime()) continue;
      console.log(
        `${s.agent_group_id}/${s.id}\n  ${r.id}  "${r.recurrence}"  tz=${tz}\n    ${r.process_after}  ->  ${next}`,
      );
      if (!dry) db.prepare('UPDATE messages_in SET process_after = ? WHERE id = ?').run(next, r.id);
      changed++;
    }
  } finally {
    db.close();
  }
}

console.log(`\n${dry ? '[dry] would re-time' : 're-timed'} ${changed} row(s)`);
