/**
 * Ops one-off: change the cron `recurrence` on a scheduled task in a session
 * inbound.db. Affects future occurrences — the current pending row keeps its
 * `process_after`, and each future clone copies the new recurrence forward
 * (see src/modules/scheduling/recurrence.ts `insertRecurrence`). Day-of-week /
 * timezone interpretation is applied at fire time via `resolveOwnerTz`.
 *
 * Run with the host STOPPED (this writes the session inbound.db, which the
 * sweep also owns — single writer per file), then start the host.
 *
 *   pnpm exec tsx scripts/set-task-recurrence.ts <path/to/inbound.db> <task-id> "<cron>"
 */
import Database from 'better-sqlite3';

const [dbPath, taskId, cron] = process.argv.slice(2);
if (!dbPath || !taskId || !cron) {
  console.error('usage: set-task-recurrence.ts <inbound.db> <task-id> "<cron>"');
  process.exit(1);
}

const db = new Database(dbPath);
try {
  const before = db
    .prepare('SELECT id, status, process_after, recurrence FROM messages_in WHERE id = ?')
    .get(taskId);
  if (!before) {
    console.error(`no task ${taskId} in ${dbPath}`);
    process.exit(1);
  }
  const info = db
    .prepare('UPDATE messages_in SET recurrence = ? WHERE id = ?')
    .run(cron, taskId);
  const after = db
    .prepare('SELECT id, status, process_after, recurrence FROM messages_in WHERE id = ?')
    .get(taskId);
  console.log('before:', before);
  console.log('after: ', after);
  console.log(`updated ${info.changes} row(s)`);
} finally {
  db.close();
}
