/**
 * Ops one-off: mark a scheduled task due *now* so the next host sweep wakes its
 * container and runs it off-cycle (e.g. force a recurring publish/brief to fire
 * immediately). The task keeps its recurrence, so after it runs the normal
 * next-occurrence still gets scheduled.
 *
 * Run with the host STOPPED (this writes the session inbound.db, which the
 * sweep also owns — single writer per file), then start the host so its first
 * sweep picks the task up.
 *
 *   pnpm exec tsx scripts/poke-task-due.ts <path/to/inbound.db> <task-id>
 */
import Database from 'better-sqlite3';

const [dbPath, taskId] = process.argv.slice(2);
if (!dbPath || !taskId) {
  console.error('usage: poke-task-due.ts <inbound.db> <task-id>');
  process.exit(1);
}

const db = new Database(dbPath);
try {
  const before = db.prepare('SELECT id, status, process_after FROM messages_in WHERE id = ?').get(taskId);
  if (!before) {
    console.error(`no task ${taskId} in ${dbPath}`);
    process.exit(1);
  }
  const due = new Date(Date.now() - 60_000).toISOString(); // 1 min in the past -> due
  const info = db.prepare("UPDATE messages_in SET process_after = ?, status = 'pending' WHERE id = ?").run(due, taskId);
  console.log('before:', before);
  console.log(`updated ${info.changes} row(s); ${taskId} now due ${due}`);
} finally {
  db.close();
}
