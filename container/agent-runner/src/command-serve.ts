/**
 * Agent commands the runner answers itself (src/commands.ts `serve`): it runs
 * the command's script and sends what the script made, with no model turn.
 * Jarvis's /surf is the first one: skills/surf-forecast/forecast.cjs does the
 * whole surf-forecast skill, which the model kept following loosely.
 *
 * The script prints JSON { photo?, text?, summary? }. The photo goes out the
 * way send_photo sends one. The summary is kept for the agent's next turn
 * (servedNotesBlock), so a question about the picture doesn't reach an agent
 * that never saw it. Anything off — a refused path, a failing script, nothing
 * to send — and the row goes on to the model untouched, whose prompt is the
 * command's own skill call.
 */
import { execFile } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync } from 'node:fs';
import { basename, join } from 'node:path';

import { touchHeartbeat } from './db/connection.js';
import { markCompleted, type MessageInRow } from './db/messages-in.js';
import { writeMessageOut } from './db/messages-out.js';
import { appendServedNote, takeServedNotes } from './db/session-state.js';
import { formatLocalTime, ownerTimezone } from './timezone.js';

/** `<skill>/<name>.cjs` under the skills mount — a row can't name anything else. */
const SERVE_RE = /^[a-z0-9-]+\/[a-z0-9-]+\.cjs$/;
const RUN_TIMEOUT_MS = 120_000;
/** Keeps the host's typing indicator alive while the script works (fresh = 6 s). */
const HEARTBEAT_EVERY_MS = 3_000;

export interface ServeOptions {
  skillsDir?: string;
  outboxDir?: string;
  /** Where the script runs; the agent's home in production. */
  cwd?: string;
}

interface ServeOutput {
  photo?: string;
  text?: string;
  summary?: string;
}

function log(msg: string): void {
  console.error(`[command-serve] ${msg}`);
}

function generateId(): string {
  return `msg-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

function runScript(path: string, cwd: string): Promise<{ ok: true; out: ServeOutput } | { ok: false; why: string }> {
  return new Promise((resolve) => {
    const beat = setInterval(touchHeartbeat, HEARTBEAT_EVERY_MS);
    touchHeartbeat();
    execFile(
      'node',
      [path],
      { cwd, timeout: RUN_TIMEOUT_MS, maxBuffer: 1024 * 1024, env: process.env },
      (err, stdout, stderr) => {
        clearInterval(beat);
        touchHeartbeat();
        if (err) {
          const why = err.killed ? `timed out after ${RUN_TIMEOUT_MS / 1000} s` : `exit ${err.code ?? '?'}`;
          resolve({ ok: false, why: `${why}: ${String(stderr).trim().slice(-300)}` });
          return;
        }
        try {
          const lines = String(stdout).trim().split('\n');
          resolve({ ok: true, out: JSON.parse(lines[lines.length - 1]) as ServeOutput });
        } catch {
          resolve({ ok: false, why: `not JSON: ${String(stdout).trim().slice(0, 200)}` });
        }
      },
    );
  });
}

/**
 * Serve every chat row whose content carries `command.serve`; return the rest.
 * A served row is marked completed here.
 */
export async function serveAgentCommands(rows: MessageInRow[], opts: ServeOptions = {}): Promise<MessageInRow[]> {
  const skillsDir = opts.skillsDir ?? '/app/skills';
  const outboxDir = opts.outboxDir ?? '/workspace/outbox';
  const cwd = opts.cwd ?? '/workspace/agent';
  const survivors: MessageInRow[] = [];

  for (const row of rows) {
    let command: { name?: unknown; serve?: unknown } | undefined;
    if (row.kind === 'chat' || row.kind === 'chat-sdk') {
      try {
        command = (JSON.parse(row.content) as { command?: typeof command }).command;
      } catch {
        command = undefined;
      }
    }
    if (!command || typeof command.serve !== 'string') {
      survivors.push(row);
      continue;
    }

    const name = String(command.name);
    const script = command.serve;
    if (!SERVE_RE.test(script)) {
      log(`/${name}: refused ${JSON.stringify(script)} — handing to the model`);
      survivors.push(row);
      continue;
    }
    const path = join(skillsDir, script);
    if (!existsSync(path)) {
      log(`/${name}: no ${path} — handing to the model`);
      survivors.push(row);
      continue;
    }

    const run = await runScript(path, cwd);
    if (!run.ok) {
      log(`/${name}: ${run.why} — handing to the model`);
      survivors.push(row);
      continue;
    }

    const { photo, text, summary } = run.out;
    const id = generateId();
    const routing = { platform_id: row.platform_id, channel_type: row.channel_type, thread_id: row.thread_id };
    if (typeof photo === 'string' && existsSync(photo)) {
      const filename = basename(photo);
      mkdirSync(join(outboxDir, id), { recursive: true });
      copyFileSync(photo, join(outboxDir, id, filename));
      writeMessageOut({
        id,
        kind: 'chat',
        ...routing,
        content: JSON.stringify({ operation: 'send_photo', caption: '', files: [filename] }),
      });
    } else if (typeof text === 'string' && text.trim()) {
      writeMessageOut({ id, kind: 'chat', ...routing, content: JSON.stringify({ text }) });
    } else {
      log(`/${name}: script gave nothing to send — handing to the model`);
      survivors.push(row);
      continue;
    }

    if (typeof summary === 'string' && summary.trim()) {
      appendServedNote({ command: name, at: new Date().toISOString(), summary });
    }
    markCompleted([row.id]);
    log(`Served /${name} without the model (${photo ? basename(photo) : 'text'})`);
  }
  return survivors;
}

/**
 * What the runner sent on the agent's behalf since its last turn, for the top
 * of the next prompt. Empty when there is nothing; each note is shown once.
 */
export function servedNotesBlock(): string {
  const notes = takeServedNotes();
  if (notes.length === 0) return '';
  const tz = ownerTimezone();
  return notes
    .map(
      (n) =>
        `<served command="/${n.command}" time="${formatLocalTime(n.at, tz)}">По команде /${n.command} ` +
        `человеку без тебя отправлено: ${n.summary}</served>`,
    )
    .join('\n');
}
