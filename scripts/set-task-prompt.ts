/**
 * Ops one-off: replace the `prompt` field inside a scheduled task's `content`
 * JSON in a session inbound.db. Other keys in the content JSON are preserved.
 * The new prompt text is read from a file (not argv) so multi-line / non-ASCII
 * prompts survive without shell-quoting hell.
 *
 * Run with the host STOPPED (this writes the session inbound.db, which the
 * sweep also owns — single writer per file), then start the host.
 *
 *   pnpm exec tsx scripts/set-task-prompt.ts <path/to/inbound.db> <task-id> <prompt-file>
 */
import Database from 'better-sqlite3';
import { readFileSync } from 'node:fs';

const [dbPath, taskId, promptFile] = process.argv.slice(2);
if (!dbPath || !taskId || !promptFile) {
  console.error('usage: set-task-prompt.ts <inbound.db> <task-id> <prompt-file>');
  process.exit(1);
}

const newPrompt = readFileSync(promptFile, 'utf8').replace(/\n+$/, ''); // trim trailing newline

const db = new Database(dbPath);
try {
  const row = db
    .prepare('SELECT id, status, process_after, recurrence, content FROM messages_in WHERE id = ?')
    .get(taskId) as { content: string } | undefined;
  if (!row) {
    console.error(`no task ${taskId} in ${dbPath}`);
    process.exit(1);
  }
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(row.content);
  } catch {
    console.error(`content of ${taskId} is not valid JSON — refusing to clobber`);
    process.exit(1);
  }
  const otherKeys = Object.keys(parsed).filter((k) => k !== 'prompt');
  parsed.prompt = newPrompt;
  const nextContent = JSON.stringify(parsed);
  const info = db
    .prepare('UPDATE messages_in SET content = ? WHERE id = ?')
    .run(nextContent, taskId);
  console.log(`task ${taskId}: updated ${info.changes} row(s); preserved keys=[${otherKeys.join(',')}]`);
  console.log(`new prompt (${newPrompt.length} chars):\n${newPrompt}`);
} finally {
  db.close();
}
