/**
 * Fresh figures for an agent command, attached before the model sees it.
 *
 * The host swaps an agent's own command (/health, /money — src/commands.ts)
 * for a prompt and stamps `command.data`: the agent's scripts whose output that
 * prompt is written from. Running them here, before the turn, saves the model a
 * tool round trip per script, and puts the figures in the prompt, which the
 * factuality gate already counts as grounded.
 *
 * Same shape as the scheduled-task pre-script (scheduling/task-script.ts): the
 * row's content is enriched in memory, the formatter renders it, and the
 * stored row is never touched.
 */
import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

import { touchHeartbeat } from './db/connection.js';
import type { MessageInRow } from './db/messages-in.js';
import { DEFAULT_AGENT_DIR } from './workout-plan.js';

/** A row can name only `scripts/<name>.js` under the agent dir — nothing else runs. */
const SCRIPT_RE = /^scripts\/[A-Za-z0-9_-]+\.(js|cjs|mjs)$/;
const RUN_TIMEOUT_MS = 30_000;
const MAX_OUTPUT_CHARS = 16_000;

export interface CommandData {
  source: string;
  output?: string;
  error?: string;
}

function log(msg: string): void {
  console.error(`[command-data] ${msg}`);
}

function runDataScript(source: unknown, agentDir: string): Promise<CommandData> {
  const name = String(source);
  if (typeof source !== 'string' || !SCRIPT_RE.test(source)) {
    return Promise.resolve({ source: name, error: 'refused: only scripts/<name>.js under the agent dir' });
  }
  const path = join(agentDir, source);
  if (!existsSync(path)) return Promise.resolve({ source, error: 'no such script' });
  return new Promise((resolve) => {
    execFile(
      process.execPath,
      [path],
      { cwd: agentDir, timeout: RUN_TIMEOUT_MS, maxBuffer: 4 * 1024 * 1024, env: process.env },
      (err, stdout, stderr) => {
        if (err) {
          const why = err.killed ? `timed out after ${RUN_TIMEOUT_MS / 1000} s` : `exit ${err.code ?? '?'}`;
          resolve({ source, error: `${why}: ${String(stderr).trim().slice(-300)}` });
          return;
        }
        let output = String(stdout).trim();
        if (output.length > MAX_OUTPUT_CHARS) output = `${output.slice(0, MAX_OUTPUT_CHARS)}\n… (обрезано)`;
        resolve({ source, output });
      },
    );
  });
}

/**
 * Run the data scripts of every chat row that carries `command.data`, and
 * return the rows with the results in `content.commandData`. The `data` list
 * is dropped from the returned row, so a second pass runs nothing.
 * Rows without command data come back as the same objects.
 */
export async function applyCommandData(
  rows: MessageInRow[],
  agentDir: string = DEFAULT_AGENT_DIR,
): Promise<MessageInRow[]> {
  const out: MessageInRow[] = [];
  for (const row of rows) {
    if (row.kind !== 'chat' && row.kind !== 'chat-sdk') {
      out.push(row);
      continue;
    }
    let content: Record<string, unknown>;
    try {
      content = JSON.parse(row.content);
    } catch {
      out.push(row);
      continue;
    }
    const command = content.command as { name?: unknown; data?: unknown } | undefined;
    if (!command || !Array.isArray(command.data) || command.data.length === 0) {
      out.push(row);
      continue;
    }
    const results: CommandData[] = [];
    for (const source of command.data) {
      touchHeartbeat();
      const result = await runDataScript(source, agentDir);
      log(`/${String(command.name)} ${result.source}: ${result.error ?? `${result.output!.length} chars`}`);
      results.push(result);
    }
    touchHeartbeat();
    out.push({
      ...row,
      content: JSON.stringify({ ...content, command: { name: command.name }, commandData: results }),
    });
  }
  return out;
}
