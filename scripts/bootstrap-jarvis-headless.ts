#!/usr/bin/env tsx
/**
 * bootstrap-jarvis-headless.ts
 *
 * One-shot ops script. Mirrors Greg's headless-cron-session model for Jarvis
 * so recurring tasks (morning brief, work-mail recap) survive iOS-app session
 * /new resets.
 *
 * Background: Jarvis's cron tasks were created inside iOS-app or Telegram
 * sessions. When a user starts a fresh conversation (/new) the previous
 * session's row in `sessions` flips from `active` to `closed`. The
 * host-sweep loop only iterates `status='active'` sessions, so any
 * pending recurring task in a closed session is silently orphaned — its
 * `process_after` is never read again. Greg avoids this by living in a
 * dedicated session row with no messaging_group_id; it never gets reset.
 *
 * What this script does:
 *
 * 1. Creates a new session for ag-1778740750341-ru9i6e (Jarvis) with
 *    `messaging_group_id=''` and `thread_id=''` and `status='active'`.
 * 2. Initializes the session folder + inbound/outbound DB schema via
 *    the host's own `initSessionFolder` (so future schema migrations
 *    stay in lock-step).
 * 3. Copies the two known recurring tasks (`task-1780894331573-g89b0g`
 *    morning brief, `task-1780648306196-q9o30q` work-mail recap) from
 *    their original closed sessions into the new headless inbound.db,
 *    rewinding `process_after` to the next cron tick.
 * 4. Marks the source rows `completed` so they don't reappear if the
 *    closed session is ever reactivated.
 *
 * Idempotent: re-running detects the existing headless session (selected
 * by `agent_group_id + status='active' + messaging_group_id=''`) and
 * exits without changes. Safe to keep around as a "redo from clean state"
 * tool — drop the row + dir and re-run.
 */

import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { getDb, initDb, runMigrations } from '../src/db/index.js';
import { createSession } from '../src/db/sessions.js';
import { initSessionFolder, openInboundDb, inboundDbPath } from '../src/session-manager.js';
import type { Session } from '../src/types.js';

const CENTRAL_DB_PATH = process.env.NANOCLAW_DB_PATH ?? 'data/v2.db';

const AGENT_GROUP_ID = 'ag-1778740750341-ru9i6e';

const MIGRATE_TASKS = [
  {
    sourceSessionId: 'sess-1780833570798-25kgr4',
    taskId: 'task-1780894331573-g89b0g',
    label: 'morning-brief',
    // Next fire: tomorrow 09:00 WITA = 01:00 UTC.
    nextProcessAfter: (): string => nextDailyUtc(1, 0),
  },
  {
    sourceSessionId: 'sess-1779670393334-ecxmfi',
    taskId: 'task-1780648306196-q9o30q',
    label: 'work-mail-recap',
    // Tue–Fri 16:30 WITA = 08:30 UTC. Find next matching slot.
    nextProcessAfter: (): string => nextWorkMailRecap(),
  },
];

function nextDailyUtc(hourUtc: number, minuteUtc: number): string {
  const now = new Date();
  const target = new Date(Date.UTC(
    now.getUTCFullYear(),
    now.getUTCMonth(),
    now.getUTCDate(),
    hourUtc,
    minuteUtc,
    0,
    0,
  ));
  if (target.getTime() <= now.getTime()) {
    target.setUTCDate(target.getUTCDate() + 1);
  }
  return target.toISOString();
}

function nextWorkMailRecap(): string {
  // recurrence: `30 16 * * 2-5` (16:30 Asia/Makassar = 08:30 UTC, Tue–Fri).
  // Walk forward day-by-day until we hit the right weekday.
  const now = new Date();
  let probe = new Date(Date.UTC(
    now.getUTCFullYear(),
    now.getUTCMonth(),
    now.getUTCDate(),
    8,
    30,
    0,
    0,
  ));
  if (probe.getTime() <= now.getTime()) {
    probe.setUTCDate(probe.getUTCDate() + 1);
  }
  // Acceptable weekdays in UTC are Tue–Fri (2–5). The cron is in
  // Asia/Makassar time, but UTC 08:30 of a UTC weekday corresponds to
  // the same calendar weekday in Makassar at 16:30 — UTC+8 push lands
  // at the same date.
  while (probe.getUTCDay() < 2 || probe.getUTCDay() > 5) {
    probe.setUTCDate(probe.getUTCDate() + 1);
  }
  return probe.toISOString();
}

function nowIso(): string {
  return new Date().toISOString();
}

function pickHeadlessSessionId(): string {
  const ts = Date.now();
  const suffix = Math.random().toString(36).slice(2, 8);
  return `sess-jarvis-headless-${ts}-${suffix}`;
}

function findExistingHeadless(): Session | null {
  const row = getDb()
    .prepare(
      "SELECT * FROM sessions WHERE agent_group_id = ? AND status = 'active' AND (messaging_group_id IS NULL OR messaging_group_id = '')",
    )
    .get(AGENT_GROUP_ID) as Session | undefined;
  return row ?? null;
}

interface SourceTaskRow {
  id: string;
  kind: string;
  timestamp: string;
  process_after: string | null;
  recurrence: string | null;
  series_id: string | null;
  trigger: number;
  platform_id: string | null;
  channel_type: string | null;
  thread_id: string | null;
  content: string;
  source_session_id: string | null;
  on_wake: number;
}

function loadSourceTask(sourceSessionId: string, taskId: string): SourceTaskRow | null {
  const db = openInboundDb(AGENT_GROUP_ID, sourceSessionId);
  try {
    const row = db
      .prepare(
        `SELECT id, kind, timestamp, process_after, recurrence, series_id, trigger,
                platform_id, channel_type, thread_id, content, source_session_id, on_wake
         FROM messages_in WHERE id = ?`,
      )
      .get(taskId) as SourceTaskRow | undefined;
    return row ?? null;
  } finally {
    db.close();
  }
}

function insertTaskIntoHeadless(
  destSessionId: string,
  src: SourceTaskRow,
  newProcessAfter: string,
  label: string,
): void {
  const db = openInboundDb(AGENT_GROUP_ID, destSessionId);
  try {
    const newId = `task-${Date.now()}-${label}`;
    db.prepare(
      `INSERT INTO messages_in
        (id, kind, timestamp, status, process_after, recurrence, series_id, tries,
         trigger, platform_id, channel_type, thread_id, content, source_session_id, on_wake)
       VALUES (?, ?, ?, 'pending', ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      newId,
      src.kind,
      nowIso(),
      newProcessAfter,
      src.recurrence,
      newId, // new series — decouples from the orphaned source series
      src.trigger,
      // Drop the channel-binding fields: the headless session has no
      // messaging group, so destination routing must go through the
      // agent's `send_message` MCP call to a named destination
      // (`sergei-iphone`, `telegram-mg-...`). Leaving these set would
      // confuse the delivery side into treating the headless container
      // as an iOS/Telegram-bound session.
      null,
      null,
      null,
      src.content,
      null,
      0,
    );
    console.log(`  task inserted: ${newId} (process_after=${newProcessAfter})`);
  } finally {
    db.close();
  }
}

function markSourceCompleted(sourceSessionId: string, taskId: string): void {
  const db = openInboundDb(AGENT_GROUP_ID, sourceSessionId);
  try {
    const res = db
      .prepare(`UPDATE messages_in SET status='completed' WHERE id = ? AND status='pending'`)
      .run(taskId);
    console.log(`  source task ${taskId} marked completed (rows=${res.changes}) in ${sourceSessionId}`);
  } finally {
    db.close();
  }
}

async function main(): Promise<void> {
  // The long-running NanoClaw service holds an exclusive WAL handle to
  // data/v2.db. Open in the same `journal_mode=WAL` so we share access
  // cleanly; pragma the WAL on init via the normal `initDb` path.
  initDb(CENTRAL_DB_PATH);
  // Schema check is cheap. Skip if the service has already migrated —
  // runMigrations is itself idempotent.
  runMigrations();

  let session = findExistingHeadless();
  if (session) {
    console.log(`Existing headless Jarvis session found: ${session.id} — nothing to do.`);
    return;
  }

  const newId = pickHeadlessSessionId();
  session = {
    id: newId,
    agent_group_id: AGENT_GROUP_ID,
    // Empty string (not NULL) to match Greg's row exactly. The
    // `messaging_groups` join in writeSessionRouting treats falsy values
    // the same — no channel routing is written for headless.
    messaging_group_id: '',
    thread_id: '',
    agent_provider: '',
    status: 'active',
    container_status: 'stopped',
    last_active: nowIso(),
    created_at: nowIso(),
  };
  createSession(session);
  initSessionFolder(AGENT_GROUP_ID, newId);
  console.log(`Created headless Jarvis session: ${newId}`);
  console.log(`  inbound.db: ${inboundDbPath(AGENT_GROUP_ID, newId)}`);

  for (const t of MIGRATE_TASKS) {
    console.log(`Migrating ${t.label} from ${t.sourceSessionId} ...`);
    const src = loadSourceTask(t.sourceSessionId, t.taskId);
    if (!src) {
      console.log(`  source row not found, skipping`);
      continue;
    }
    insertTaskIntoHeadless(newId, src, t.nextProcessAfter(), t.label);
    markSourceCompleted(t.sourceSessionId, t.taskId);
  }

  console.log('Done.');
}

// Allow running via either bare invocation or import. ESM "main module"
// detection: compare resolved import.meta.url to argv[1].
const isMain = fileURLToPath(import.meta.url) === path.resolve(process.argv[1] ?? '');
if (isMain) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
