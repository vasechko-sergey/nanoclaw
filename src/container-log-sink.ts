import fs from 'fs';
import path from 'path';
import { LOGS_DIR } from './config.js';

/**
 * Split a raw stderr chunk into complete, prefix-tagged lines for the central
 * container log, carrying an incomplete trailing line across chunks.
 *
 * stderr `data` events don't align to line boundaries, so a single logical line
 * (e.g. one `console.error`) can arrive split across two chunks, or two lines
 * can arrive in one. `pending` is the leftover partial line from the previous
 * chunk; the returned `rest` is the new leftover to feed back next time. `out`
 * is the complete lines, each rendered `"<prefix> <line>\n"`. Blank lines are
 * dropped so the aggregate log isn't peppered with bare prefixes. Pure — no
 * I/O — so the line-assembly logic is unit-tested without a stream or a
 * spawned container.
 */
export function splitPrefixedLines(
  prefix: string,
  pending: string,
  chunk: string,
): { out: string; rest: string } {
  const parts = (pending + chunk).split('\n');
  const rest = parts.pop() ?? '';
  const out = parts
    .filter((line) => line !== '')
    .map((line) => `${prefix} ${line}\n`)
    .join('');
  return { out, rest };
}

let centralStream: fs.WriteStream | null = null;
let centralStreamFailed = false;

/**
 * Append already-formatted text to the central `logs/containers.log` — the
 * single, logrotate-covered aggregate of every container's stderr (the
 * per-session `<sessionDir>/container.log` stays as the near-term per-container
 * view). Lazily opens one append stream for the host process; O_APPEND is
 * chosen so logrotate's `copytruncate` works — after the file is truncated the
 * next write lands at the (now zero) end without reopening the fd. Best-effort:
 * any failure disables the sink for the process rather than throwing into the
 * spawn path.
 */
export function appendCentralContainerLog(text: string): void {
  if (!text || centralStreamFailed) return;
  try {
    if (!centralStream) {
      fs.mkdirSync(LOGS_DIR, { recursive: true });
      centralStream = fs.createWriteStream(path.join(LOGS_DIR, 'containers.log'), { flags: 'a' });
    }
    centralStream.write(text);
  } catch {
    centralStreamFailed = true;
  }
}
